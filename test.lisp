;;; -*- show-trailing-whitespace: t; indent-tabs: nil -*-
;;;
;;; Copyright (c) 2007 David Lichteblau. All rights reserved.

;;; Redistribution and use in source and binary forms, with or without
;;; modification, are permitted provided that the following conditions
;;; are met:
;;;
;;;   * Redistributions of source code must retain the above copyright
;;;     notice, this list of conditions and the following disclaimer.
;;;
;;;   * Redistributions in binary form must reproduce the above
;;;     copyright notice, this list of conditions and the following
;;;     disclaimer in the documentation and/or other materials
;;;     provided with the distribution.
;;;
;;; THIS SOFTWARE IS PROVIDED BY THE AUTHOR 'AS IS' AND ANY EXPRESSED
;;; OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
;;; WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
;;; ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
;;; DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
;;; DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
;;; GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
;;; INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
;;; WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
;;; NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
;;; SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


(in-package :cxml-rng)

(defun run-tests (&optional (p "/home/david/src/lisp/cxml-rng/spec-split/*"))
  (dribble "/home/david/src/lisp/cxml-rng/TEST" :if-exists :rename-and-delete)
  (let ((pass 0)
	(total 0)
	(*package* (find-package :cxml-rng))
	(*print-level* 3))
    (dolist (d (directory p))
      (let ((name (car (last (pathname-directory d)))))
	(when (parse-integer name :junk-allowed t)
	  (let ((xml (directory (merge-pathnames "*.xml" d))))
	    (incf total (1+ (length xml)))
	    (multiple-value-bind (ok grammar) (test1 d)
	      (cond
		(ok
		 (incf pass (1+ (run-validation-tests name grammar xml))))
		(t
		 (dolist (x xml)
		   (format t "~A-~D: FAIL: cannot run test~%"
			   name
			   (pathname-name x))))))))))
    (format t "Passed ~D/~D tests.~%" pass total))
  (dribble))

(defun run-validation-test
    (m n &optional (p "/home/david/src/lisp/cxml-rng/spec-split/"))
  (let ((d (merge-pathnames (format nil "~3,'0D/" m) p))
	(*break-on-signals* 'error)
	(*debug* t)
	(*print-level* 3))
    (run-validation-tests m
			  (nth-value 1 (test1 d))
			  (list (let ((v (merge-pathnames
					  (format nil "~A.v.xml" n)
					  d)))
				  (if (probe-file v)
				      v
				      (merge-pathnames
				       (format nil "~A.i.xml" n)
				       d)))))))

(defun run-validation-tests (name grammar tests)
  (let ((pass 0))
    (dolist (x tests)
      (format t "~A-~D: " name (pathname-name x))
      (flet ((doit ()
	       (cxml:parse-file x (make-validator grammar))))
	(if (find #\v (pathname-name x))
	    (handler-case
		(progn
		  (doit)
		  (incf pass)
		  (format t "PASS~%"))
	      (error (c)
		(format t "FAIL: ~A~%" c)))
	    (handler-case
		(progn
		  (doit)
		  (format t "FAIL: didn't detect invalid document~%"))
	      (rng-error (c)
		(incf pass)
		(format t "PASS: ~A~%" (type-of c)))
	      (error (c)
		(format t "FAIL: incorrect condition type: ~A~%" c))))))
    pass))

(defun run-test (n &optional (p "/home/david/src/lisp/cxml-rng/spec-split/"))
  (test1 (merge-pathnames (format nil "~3,'0D/" n) p)))

(defun parse-test (n &optional (p "/home/david/src/lisp/cxml-rng/spec-split/"))
  (let* ((*debug* t)
	 (d (merge-pathnames (format nil "~3,'0D/" n) p))
	 (i (merge-pathnames "i.rng" d))
	 (c (merge-pathnames "c.rng" d))
	 (rng (if (probe-file c) c i)))
    (format t "~A: " (car (last (pathname-directory d))))
    (print rng)
    (parse-relax-ng rng)))

(defun test1 (d)
  (let* ((i (merge-pathnames "i.rng" d))
	 (c (merge-pathnames "c.rng" d)))
    (format t "~A: " (car (last (pathname-directory d))))
    (if (probe-file c)
	(handler-case
	    (let ((grammar (parse-relax-ng c)))
	      (format t " PASS~%")
	      (values t grammar))
	  (error (c)
	    (format t " FAIL: ~A~%" c)
	    nil))
	(handler-case
	    (progn
	      (parse-relax-ng i)
	      (format t " FAIL: didn't detect invalid schema~%")
	      nil)
	  (rng-error (c)
	    (format t " PASS: ~S~%" (type-of c))
	    t)
	  (error (c)
	    (format t " FAIL: incorrect condition type: ~A~%" c)
	    nil)))))

(defun run-nist-tests
    (&optional (p #p"/home/david/NISTSchemaTests/NISTXMLSchemaTestSuite.xml"))
  (dribble "/home/david/src/lisp/cxml-rng/NIST" :if-exists :rename-and-delete)
  (klacks:with-open-source (s (cxml:make-source p))
    (let ((total 0)
	  (pass 0))
      (loop
	 while (klacks:find-element s "Link")
	 do
	   (multiple-value-bind (n i)
	       (run-nist-tests/link (klacks:get-attribute s "href") p)
	     (incf total n)
	     (incf pass i))
	   (klacks:consume s))
      (format t "Passed ~D/~D tests.~%" pass total)))
  (dribble))

(defun run-nist-tests/link (href base)
  (klacks:with-open-source (r (cxml:make-source (merge-pathnames href base)))
    (let ((total 0)
	  (pass 0))
      (let (schema)
	(loop
	   (multiple-value-bind (key uri lname)
	       (klacks:peek-next r)
	     uri
	     (unless key
	       (return)) 
	     (when (eq key :start-element)
	       (cond
		 ((equal lname "Schema")
		  (incf total)
		  (setf schema
			(read-nist-grammar (klacks:get-attribute r "href")
					   base))
		  (when schema
		    (incf total)))
		 ((equal lname "Instance")
		  (incf total)
		  (when (run-nist-test/Instance schema
						(klacks:get-attribute r "href")
						base)
		    (incf pass))))))))
      (values total pass))))

(defun run-nist-test/Instance (schema href base)
  (cond
    (schema
     (handler-case
	 (progn
	   (cxml:parse-file (merge-pathnames href base)
			    (make-validator schema))
	   (format t "PASS INSTANCE ~A~%" href)
	   t)
       (rng-error (c)
	 (format t "FAIL INSTANCE ~A: failed to validate:~_ ~A~%" href c)
	 nil)
       (error (c)
	 (format t "FAIL INSTANCE ~A: (BOGUS CONDITON) failed to validate:~_ ~A~%" href c)
	 nil)))
    (t
     (format t "FAIL ~A: no schema~%" href)
     nil)))

(defun read-nist-grammar (href base)
  (let ((p (make-pathname :type "rng" :defaults href)))
    (handler-case
	(prog1
	    (parse-relax-ng (merge-pathnames p base))
	  (format t "PASS ~A~%" href)
	  t)
      (rng-error (c)
	(format t "FAIL ~A: failed to parse:~_ ~A~%" href c)
	nil)
      (error (c)
	(format t "FAIL ~A: (BOGUS CONDITION) failed to parse:~_ ~A~%" href c)
	nil))))
