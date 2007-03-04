(in-package :cxml-rng)


;;;; Errors

(define-condition rng-error (simple-error) ())

(defun rng-error (fmt &rest args)
  (error 'rng-error :format-control fmt :format-arguments args))


;;;; Parser

(defvar *datatype-library*)
(defvar *entity-resolver*)
(defvar *external-href-stack*)
(defvar *include-href-stack*)

(defun parse-relax-ng (input &key entity-resolver)
  (handler-case
      (klacks:with-open-source (source (cxml:make-source input))
	(klacks:find-event source :start-element)
	(let ((*datatype-library* "")
	      (*entity-resolver* entity-resolver)
	      (*external-href-stack* '())
	      (*include-href-stack* '()))
	  (p/pattern source)))
    (cxml:xml-parse-error (c)
      (rng-error "Cannot parse schema: ~A" c))))


;;;; pattern structures

(defstruct pattern
  ns)

(defstruct (%combination (:include pattern) (:conc-name "PATTERN-"))
  possibilities)

(defstruct (%named-pattern (:include pattern) (:conc-name "PATTERN-"))
  name)

(defstruct (element (:include %named-pattern) (:conc-name "PATTERN-"))
  children)

(defstruct (attribute (:include %named-pattern) (:conc-name "PATTERN-"))
  child)

(defstruct (group (:include %combination) (:conc-name "PATTERN-")))
(defstruct (interleave (:include %combination) (:conc-name "PATTERN-")))
(defstruct (choice (:include %combination) (:conc-name "PATTERN-")))
(defstruct (optional (:include %combination) (:conc-name "PATTERN-")))
(defstruct (zero-or-more (:include %combination) (:conc-name "PATTERN-")))
(defstruct (one-or-more (:include %combination) (:conc-name "PATTERN-")))
(defstruct (list-pattern (:include %combination) (:conc-name "PATTERN-")))
(defstruct (mixed (:include %combination) (:conc-name "PATTERN-")))

(defstruct (ref (:include %named-pattern) (:conc-name "PATTERN-")))

(defstruct (parent-ref (:include %named-pattern) (:conc-name "PATTERN-")))

(defstruct (empty (:include pattern) (:conc-name "PATTERN-")))
(defstruct (text (:include pattern) (:conc-name "PATTERN-")))

(defstruct (%typed-pattern (:include pattern) (:conc-name "PATTERN-"))
  datatype-library)

(defstruct (value (:include %typed-pattern) (:conc-name "PATTERN-"))
  string)

(defstruct (data (:include %typed-pattern) (:conc-name "PATTERN-"))
  type
  params
  except)

(defstruct (not-allowed (:include pattern) (:conc-name "PATTERN-")))

(defstruct (grammar (:include pattern) (:conc-name "PATTERN-"))
  content)


;;;; non-pattern

(defstruct param
  name
  string)

(defstruct start
  combine
  child)

(defstruct define
  name
  combine
  children)

(defstruct div
  content)

(defstruct include
  href
  content)


;;;; parser

(defvar *rng-namespace* "http://relaxng.org/ns/structure/1.0")

(defun skip-foreign (source)
  (when (equal (klacks:current-uri source) *rng-namespace*)
    (rng-error "invalid schema: ~A not allowed here"
	       (klacks:current-lname source)))
  (klacks:serialize-element source nil))

(defun attribute (lname attrs)
  (let ((a (sax:find-attribute-ns "" lname attrs)))
    (if a
	(sax:attribute-value a)
	nil)))

(defvar *whitespace*
    (format nil "~C~C~C"
	    (code-char 9)
	    (code-char 32)
	    (code-char 13)
	    (code-char 10)))

(defun ntc (lname attrs)
  ;; used for (n)ame, (t)ype, and (c)ombine, this also strings whitespace
  (let ((a (sax:find-attribute-ns "" lname attrs)))
    (if a
	(string-trim *whitespace* (sax:attribute-value a))
	nil)))

(defmacro with-datatype-library (attrs &body body)
  `(invoke-with-datatype-library (lambda () ,@body) ,attrs))

(defun invoke-with-datatype-library (fn attrs)
  (let* ((dl (attribute "datatypeLibrary" attrs))
	 (*datatype-library* (if dl (escape-uri dl) *datatype-library*)))
    (funcall fn)))

(defun p/pattern (source)
  (let* ((lname (klacks:current-lname source))
	 (attrs (klacks:list-attributes source))
	 (ns (attribute "ns" attrs)))
    (with-datatype-library attrs
      (case (find-symbol lname :keyword)
	(:|element|     (p/element source (ntc "name" attrs) ns))
	(:|attribute|   (p/attribute source (ntc "name" attrs) ns))
	(:|group|       (p/combination #'make-group source ns))
	(:|interleave|  (p/combination #'make-interleave source ns))
	(:|choice|      (p/combination #'make-choice source ns))
	(:|optional|    (p/combination #'make-optional source ns))
	(:|zeroOrMore|  (p/combination #'make-zero-or-more source ns))
	(:|oneOrMore|   (p/combination #'make-one-or-more source ns))
	(:|list|        (p/combination #'make-list-pattern source ns))
	(:|mixed|       (p/combination #'make-mixed source ns))
	(:|ref|         (p/ref source ns))
	(:|parentRef|   (p/parent-ref source ns))
	(:|empty|       (p/empty source ns))
	(:|text|        (p/text source ns))
	(:|value|       (p/value source ns))
	(:|data|        (p/data source ns))
	(:|externalRef| (p/external-ref source ns))
	(:|grammar|     (p/grammar source ns))
	(t (skip-foreign source))))))

(defun p/pattern+ (source)
  (let ((children nil))
    (loop
      (case (klacks:peek-next source)
	(:start-element
	  (let ((p (p/pattern source))) (when p (push p children))))
	(:end-element (return))))
    (unless children
      (error "empty element"))
    (nreverse children)))

(defun p/pattern? (source)
  (loop
    (case (klacks:peek-next source)
      (:start-element (return (p/pattern source)))
      (:end-element (return)))))

(defun p/element (source name ns)
  (klacks:expecting-element (source "element")
    (let ((result (make-element :ns ns)))
      (if name
	  (setf (pattern-name result) (list :name name))
	  (setf (pattern-name result) (p/name-class source)))
      (setf (pattern-children result) (p/pattern+ source))
      result)))

(defun p/attribute (source name ns)
  (klacks:expecting-element (source "attribute")
    (let ((result (make-attribute :ns ns)))
      (if name
	  (setf (pattern-name result) (list :name name))
	  (setf (pattern-name result) (p/name-class source)))
      (setf (pattern-child result) (p/pattern? source))
      result)))

(defun p/combination (constructor source ns)
  (klacks:expecting-element (source)
    (let ((possibility (p/pattern+ source)))
      (funcall constructor :possibility possibility :ns ns))))

(defun p/ref (source ns)
  (klacks:expecting-element (source "ref")
    (make-ref :name (ntc "name" (klacks:list-attributes source))
	      :ns ns)))

(defun p/parent-ref (source ns)
  (klacks:expecting-element (source "parentRef")
    (make-parent-ref :name (ntc "name" (klacks:list-attributes source))
		     :ns ns)))

(defun p/empty (source ns)
  (klacks:expecting-element (source "empty")
    (klacks:consume source)
    (make-empty :ns ns)))

(defun p/text (source ns)
  (klacks:expecting-element (source "text")
    (klacks:consume source)
    (make-text :ns ns)))

(defun parse-characters (source)
  ;; fixme
  (let ((tmp ""))
    (loop
      (multiple-value-bind (key data) (klacks:peek-next source)
	(case key
	  (:characters
	    (setf tmp (concatenate 'string tmp data)))
	  (:end-element (return)))))
    tmp))

(defun p/value (source ns)
  (klacks:expecting-element (source "value")
    (let* ((type (ntc "type" (klacks:list-attributes source)))
	   (string (parse-characters source))
	   (dl *datatype-library*))
      (unless type
	(setf type "token")
	(setf dl ""))
      (make-value :string string :type type :datatype-library dl :ns ns))))

(defun p/data (source ns)
  (klacks:expecting-element (source "data")
    (let* ((type (ntc "type" (klacks:list-attributes source)))
	   (result (make-data :type type
			      :datatype-library *datatype-library*
			      :ns ns))
	   (params '()))
      (loop
	(multiple-value-bind (key lname)
	    (klacks:peek-next source)
	  (case key
	    (:start-element
	      (case (find-symbol lname :keyword)
		(:|param| (push (p/param source) params))
		(:|except|
		  (setf (pattern-except result) (p/except-pattern source))
		  (return))
		(t (skip-foreign source))))
	    (:end-element
	      (return)))))
      (setf (pattern-params result) (nreverse params))
      result)))

(defun p/param (source)
  (klacks:expecting-element (source "param")
    (let ((name (ntc "name" (klacks:list-attributes source)))
	  (string (parse-characters source)))
      (make-param :name name :string string))))

(defun p/except-pattern (source)
  (klacks:expecting-element (source "except")
    (with-datatype-library (klacks:list-attributes source)
      (p/pattern+ source))))

(defun p/not-allowed (source ns)
  (klacks:expecting-element (source "notAllowed")
    (make-not-allowed :ns ns)))

(defun p/external-ref (source ns)
  (klacks:expecting-element (source "externalRef")
    (let ((href
	   (escape-uri (attribute "href" (klacks:list-attributes source)))))
      (when (find href *include-href-stack* :test #'string=)
	(error "looping include"))
      (let* ((*include-href-stack* (cons href *include-href-stack*))
	     (xstream (cxml::xstream-open-extid* *entity-resolver* nil href))
	     (result
	      (klacks:with-open-source (source (cxml:make-source xstream))
		(klacks:find-event source :start-element)
		(let ((*datatype-library* ""))
		  (p/pattern source)))))
	(unless (pattern-ns result)
	  (setf (pattern-ns result) ns))
	result))))

(defun p/grammar (source ns)
  (klacks:expecting-element (source "grammar")
    (make-grammar :content (p/grammar-content* source) :ns ns)))

(defun p/grammar-content* (source &key disallow-include)
  (let ((content nil))
    (loop
      (multiple-value-bind (key lname) (klacks:peek-next source)
	(case key
	  (:start-element
	    (with-datatype-library (klacks:list-attributes source)
	      (case (find-symbol lname :keyword)
		(:|start| (push (p/start source) content))
		(:|define| (push (p/define source) content))
		(:|div| (push (p/div source) content))
		(:|include|
		  (when disallow-include
		    (error "nested include not permitted"))
		  (push (p/include source) content))
		(t (skip-foreign source)))))
	  (:end-element (return)))))
    (nreverse content)))

(defun p/start (source)
  (klacks:expecting-element (source "start")
    (let ((combine (ntc "combine" source))
	  (child (p/pattern source)))
      (make-start :combine (find-symbol (string-upcase combine) :keyword)
		  :child child))))

(defun p/define (source)
  (klacks:expecting-element (source "define")
    (let ((name (ntc "name" source))
	  (combine (ntc "combine" source))
	  (children (p/pattern+ source)))
      (make-define :name name
		   :combine (find-symbol (string-upcase combine) :keyword)
		   :children children))))

(defun p/div (source)
  (klacks:expecting-element (source "div")
    (make-div :content (p/grammar-content* source))))

(defun p/include (source)
  (klacks:expecting-element (source "include")
    (let ((href
	   (escape-uri (attribute "href" (klacks:list-attributes source))))
	  (include-content (p/grammar-content* source :disallow-include t)))
      (when (find href *include-href-stack* :test #'string=)
	(error "looping include"))
      (let* ((*include-href-stack* (cons href *include-href-stack*))
	     (xstream (cxml::xstream-open-extid* *entity-resolver* nil href))
	     (grammar
	      (klacks:with-open-source (source (cxml:make-source xstream))
		(klacks:find-event source :start-element)
		(let ((*datatype-library* ""))
		  (p/grammar source "wrong://"))))
	     (grammar-content (pattern-content grammar)))
	(make-div :children
		  (cons (make-div :children
				  (simplify-include grammar-content
						    include-content))
			include-content))))))

(defun simplify-include/map (fn l)
  (loop
      for x in l
      for value = (let ((result (funcall fn x)))
		    (when (typep x 'div)
		      (loop
			  for x in (div-content x)
			  for value = (funcall fn x)
			  when value
			  collect value into content
			  finally
			    (setf (div-content x) content)))
		    result)
      when value
      collect value))

(defun simplify-include/start (grammar-content include-content)
  (let ((startp
	 (block nil
	   (simplify-include/map (lambda (x)
				   (when (typep x 'start)
				     (return t))
				   x)
				 include-content))))
    (if startp
	(let ((ok nil))
	  (prog1
	      (simplify-include/map (lambda (x)
				      (cond
					((typep x 'start) (setf ok t) nil)
					(t x)))
				    grammar-content))
	  (unless ok
	    (error "expected start in grammar")))
	grammar-content)))

(defun simplify-include/define (grammar-content include-content)
  (let ((defines '()))
    (simplify-include/map (lambda (x)
			    (when (typep x 'define)
			      (push (cons x nil) defines))
			    x)
			  include-content)
    (prog1
	(simplify-include/map
	 (lambda (x)
	   (if (typep x 'define)
	       (let ((cons (find (define-name x) defines :key #'car)))
		 (cond
		   (cons
		     (setf (cdr cons) t)
		     nil)
		   (t
		     x)))
	       x))
	 grammar-content)
      (loop for (define . okp) in defines do
	    (unless okp
	      (error "expected matching ~A in grammar" define))))))

(defun simplify-include (grammar-content include-content)
  (simplify-include/define
   (simplify-include/start grammar-content include-content)
   include-content))

(defun p/name-class (source)
  (klacks:expecting-element (source)
    (with-datatype-library (klacks:list-attributes source)
      (case (find-symbol (klacks:current-lname source) :keyword)
	(:|name|
	  (list :name (string-trim *whitespace* (parse-characters source))))
	(:|anyName|
	  (cons :any (p/except-name-class? source)))
	(:|nsName|
	  (cons :ns (p/except-name-class? source)))
	(:|choice|
	  (cons :choice (p/name-class* source)))
	(t
	  (skip-foreign source))))))

(defun p/name-class* (source)
  (let ((results nil))
    (loop
      (case (klacks:peek-next source)
	(:start-element (push (p/name-class source) results))
	(:end-element (return))))
    (nreverse results)))

(defun p/except-name-class? (source)
  (loop
    (multiple-value-bind (key lname)
	(klacks:peek-next source)
      (unless (eq key :start-element)
	(return))
      (when (string= (find-symbol lname :keyword) "except")
	(return (p/except-name-class source)))
      (skip-foreign source))))

(defun p/except-name-class (source)
  (klacks:expecting-element (source "except")
    (with-datatype-library (klacks:list-attributes source)
      (cons :except (p/name-class source)))))

(defun escape-uri (string)
  (with-output-to-string (out)
    (loop for c across (cxml::rod-to-utf8-string string) do
	  (let ((code (char-code c)))
	    ;; http://www.w3.org/TR/xlink/#link-locators
	    (if (or (>= code 127) (<= code 32) (find c "<>\"{}|\\^`"))
		(format out "%~2,'0X" code)
		(write-char c out))))))


;;;; simplification

;;; 4.1 Annotations
;;;   Foreign attributes and elements are removed implicitly while parsing.

;;; 4.2 Whitespace
;;;   All character data is discarded while parsing (which can only be
;;;   whitespace after validation).
;;;
;;;   Whitespace in name, type, and combine attributes is stripped while
;;;   parsing.  Ditto for <name/>.

;;; 4.3. datatypeLibrary attribute
;;;   Escaping is done by p/pattern.
;;;   Attribute value defaulting is done using *datatype-library*; only
;;;   p/data and p/value record the computed value.

;;; 4.4. type attribute of value element
;;;   Done by p/value.

;;; 4.5. href attribute
;;;   Escaping is done by p/include and p/external-ref.
;;;
;;;   FIXME: Mime-type handling should be the job of the entity resolver,
;;;   but that requires xstream hacking.

;;; 4.6. externalRef element
;;;   Done by p/external-ref.

;;; 4.7. include element
;;;   Done by p/include.


;;;; tests

(defun test (&optional (p "/home/david/src/lisp/cxml-rng/spec-split/*"))
  (dribble "/home/david/src/lisp/cxml-rng/TEST")
  (let ((pass 0)
	(total 0))
    (dolist (d (directory p))
      (let ((name (car (last (pathname-directory d)))))
	(when (parse-integer name :junk-allowed t)
	  (incf total)
	  (let* ((i (merge-pathnames "i.rng" d))
		 (c (merge-pathnames "c.rng" d)))
	    (format t "~A: " name)
	    (if (probe-file c)
		(handler-case
		    (progn
		      (parse-relax-ng c)
		      (format t " PASS~%")
		      (incf pass))
		  (error (c)
		    (format t " FAIL: ~A~%" c)))
		(handler-case
		    (progn
		      (parse-relax-ng i)
		      (format t " FAIL: didn't detect invalid schema~%"))
		  (rng-error (c)
		    (format t " PASS: ~A~%" c)
		    (incf pass))
		  (error (c)
		    (format t " FAIL: incorrect condition type: ~A~%" c))))))))
    (format t "Passed ~D/~D tests.~%" pass total))
  (dribble))
