(in-package :plus-c)

(defvar *topmost-parent* nil)
(defvar *final-value-set* nil)

 ;; Function calling

(defmacro c-fun (name &rest args)
  (if-let (fun (find-function name))
    (with-slots ((type autowrap::type)
                 (c-symbol autowrap::c-symbol)
                 (fields autowrap::fields)) fun
      (autowrap::foreign-wrap-up
       type fun
       `(cffi-sys:%foreign-funcall ,c-symbol
                                   (,@(loop for f in fields
                                            for a in args
                                            collect (basic-foreign-type f)
                                            collect a)
                                    ,@(nthcdr (length fields) args)
                                    ,(basic-foreign-type type)))))
    (error 'c-unknown-function :name name)))

 ;; Refs

;;; Because for some reason CFFI-SYS doesn't:
(declaim (inline mem-ref (setf mem-ref)))
(defun mem-ref (ptr type)
  (cffi-sys:%mem-ref ptr type))

(defun (setf mem-ref) (value ptr type)
  (cffi-sys:%mem-set value ptr type))

;;;
;;; (c:ref TYPE wrapper-or-pointer [FIELD ...] FINAL-FIELD)
;;;
;;; Ref types:
;;;
;;; SYMBOL - reference a field; if this is FINAL-FIELD, return a
;;; wrapper or value.  Multiple SYMBOL in a row will dereference
;;; fields, either by X.Y or X->Y
;;;
;;; INTEGER - array reference prior type; if this is the first field,
;;; array reference of TYPE, e.g., (c:ref :int x 42)
;;;
;;; * (the symbol, *) - deref a pointer; if this is a final field,
;;; return a wrapper or value
;;;
;;; & (the symbol, &) - as FINAL-FIELD only, returns the address of
;;; the last field
(defmacro c-ref (wrapper type &rest fields)
  (if-let (type (find-type type))
    (once-only (wrapper)
      (let ((*topmost-parent* wrapper))
        (build-ref (car fields) type `(autowrap:ptr ,wrapper) (cdr fields))))))

;;; FIXME: now that we have MEM-REF locally with (SETF MEM-REF),
;;; this could be cleaned back up
(define-setf-expander c-ref (wrapper type &rest fields)
  (when-let (type (find-type type))
    (with-gensyms (v)
      (let ((*final-value-set* v))
        (values
         nil nil
         `(,v)
         (build-ref (car fields) type `(autowrap:ptr ,wrapper)
                    (cdr fields))
         wrapper)))))

(defgeneric build-ref (ref type current-ref rest))

(defmethod build-ref (ref type current-ref rest)
  (error "Error parsing ref: ~S on type ~S" ref type))

(defmethod build-ref (ref (type foreign-alias) current-ref rest)
  (build-ref ref (foreign-type type) current-ref rest))

(defmethod build-ref (ref (type foreign-pointer) current-ref rest)
  (if rest
      (build-ref (car rest) type current-ref (cdr rest))
      (if ref
          (build-ref ref (foreign-type type)
                     `(cffi-sys:%mem-ref ,current-ref :pointer) rest)
          (if *final-value-set*
              `(cffi-sys:%mem-set ,*final-value-set* ,current-ref :pointer)
              current-ref))))

(defmethod build-ref ((ref symbol) (type foreign-record) current-ref rest)
  (if-let (field (find-record-field type ref))
    (if (frf-bitfield-p field)
        (if *final-value-set*
            (once-only (current-ref)
              `(cffi-sys:%mem-set ,(autowrap::make-bitfield-merge field current-ref *final-value-set*)
                                  ,current-ref ,(basic-foreign-type (foreign-type field))))
            (autowrap::make-bitfield-deref field current-ref))
        (build-ref (car rest) (foreign-type field)
                   (autowrap::make-field-ref field current-ref) (cdr rest)))
    (error 'c-unknown-field :type type :field ref)))

(defmethod build-ref ((ref (eql '*)) (type foreign-pointer)
                      current-ref rest)
  (let ((child-type (foreign-type type)))
    (build-ref nil child-type current-ref rest)))

(defmethod build-ref ((ref (eql '&)) type current-ref rest)
  (when rest
    (error "& may only be used at the end of a ref"))
  (when (and (typep type 'foreign-record-field)
             (frf-bitfield-p type))
    (error "You may not take the address of a bitfield"))
  current-ref)

(defmethod build-ref ((ref integer) (type foreign-pointer) current-ref rest)
  (build-ref (car rest) (foreign-type type)
             (autowrap::make-array-ref type current-ref ref)
             (cdr rest)))

(defmethod build-ref ((ref symbol) (type foreign-array) current-ref rest)
  (build-ref ref (foreign-type type)
             (autowrap::make-array-ref type current-ref 0)
             (cdr rest)))

(defmethod build-ref ((ref null) (type symbol) current-ref rest)
  (if (keywordp type)
      (if *final-value-set*
          `(cffi-sys:%mem-set ,*final-value-set* ,current-ref ,type)
          `(cffi-sys:%mem-ref ,current-ref ,type))
      (error "Not a basic type: ~S" type)))

(defmethod build-ref ((ref null) (type foreign-record) current-ref rest)
  (if *final-value-set*
      (error "You may not set the value of a record (~S)" type)
      (with-gensyms (v)
        `(let ((,v (make-instance ',(let ((name (foreign-type-name type)))
                                      (if (symbol-package name)
                                          name
                                          'autowrap:anonymous-type)))))
           (setf (autowrap::wrapper-ptr ,v) ,current-ref)
           (setf (autowrap::wrapper-validity ,v) ,*topmost-parent*)
           ,v))))

 ;; c-let

(defun make-bindings (bindings rest)
  (flet ((maybe-make-macro (tmp v c-type)
           (with-gensyms (r)
             `((macrolet ((,v (&rest ,r)
                            `(plus-c:c-ref ,',tmp ,',c-type ,@,r)))
                 ,(if (keywordp c-type)
                      `(symbol-macrolet ((,v (mem-ref ,tmp ',c-type)))
                         ,@(make-bindings (cdr bindings) rest))
                      `(symbol-macrolet ((,v ,tmp))
                         ,@(make-bindings (cdr bindings) rest))))))))
    (if bindings
        (with-gensyms (tmp)
          (destructuring-bind (v c-type &key (count 1) free ptr)
              (car bindings)
            (if ptr
                (if (keywordp c-type)
                    `(symbol-macrolet ((,v `(mem-ref ,ptr ',c-type)))
                       ,@(make-bindings (cdr bindings) rest))
                    `(let ((,tmp (let ((,tmp (make-instance ',c-type)))
                                   (setf (autowrap::wrapper-ptr ,tmp) ,ptr)
                                   ,tmp)))
                       ,@(maybe-make-macro tmp v c-type)))
                (if free
                    `(with-alloc (,tmp ',c-type ,count)
                       ,@(maybe-make-macro tmp v c-type))
                    `(let ((,tmp (autowrap:alloc ',c-type ,count)))
                       ,@(maybe-make-macro tmp v c-type))))))
        rest)))

(defmacro c-let (bindings &body body)
  (make-bindings bindings body))