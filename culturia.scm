(define-module (culturia))

(use-modules (culturia wiredtiger))

(use-modules (rnrs hashtables))

(use-modules (srfi srfi-1))
(use-modules (srfi srfi-9))  ;; records
(use-modules (srfi srfi-9 gnu))  ;; set-record-type-printer!
(use-modules (srfi srfi-19))  ;; date
(use-modules (srfi srfi-26))  ;; cut
(use-modules (srfi srfi-41))  ;; stream

(use-modules (ice-9 match))
(use-modules (ice-9 format))
(use-modules (ice-9 optargs))  ;; lambda*
(use-modules (ice-9 receive))


;; helper for managing exceptions

(define (make-exception name)
  "Generate a unique symbol prefixed with NAME"
  (gensym (string-append "culturia-" name "-")))

(define *exception* (make-exception "exception"))

(define (raise message . rest)
  "shorthand to throw EXCEPTION with MESSAGE formated with REST"
  (throw *exception* (apply format (append (list #false message) rest))))

;; well, i'm too lazy to create other error messages
(define (Oops!)
  (raise "Oops!"))

;; ---

;;;
;;; srfi-99
;;;
;;
;; macro to quickly define immutable records
;;
;;
;; Usage:
;;
;;   (define-record-type <abc> field-one field-two)
;;   (define zzz (make-abc 1 2))
;;   (abc-field-one zzz) ;; => 1
;;

(define-syntax define-record-type*
  (lambda (x)
    (define (%id-name name) (string->symbol (string-drop (string-drop-right (symbol->string name) 1) 1)))
    (define (id-name ctx name)
      (datum->syntax ctx (%id-name (syntax->datum name))))
    (define (id-append ctx . syms)
      (datum->syntax ctx (apply symbol-append (map syntax->datum syms))))
    (syntax-case x ()
      ((_ rname field ...)
       (and (identifier? #'rname) (and-map identifier? #'(field ...)))
       (with-syntax ((cons (id-append #'rname #'make- (id-name #'rname #'rname)))
                     (pred (id-append #'rname (id-name #'rname #'rname) #'?))
                     ((getter ...) (map (lambda (f)
                                          (id-append f (id-name #'rname #'rname) #'- f))
                                        #'(field ...))))
         #'(define-record-type rname
             (cons field ...)
             pred
             (field getter)
             ...))))))

;; ---

;;;
;;; generate-uid
;;;

;; init random with a random state

(set! *random-state* (random-state-from-platform))

(define-public (random-name exists?)
  "Generate a random string made up alphanumeric ascii chars that doesn't exists
   according to `exists?`"
  (define (random-id)
    (define CHARS "0123456789AZERTYUIOPQSDFGHJKLMWXCVBN")
    ;; append 8 alphanumeric chars from `CHARS`
    ;; 281 474 976 710 656 possible names
    (let loop ((count 8)
               (id ""))
      (if (eq? count 0)
          id
          (loop (1- count) (format #f "~a~a" id (string-ref CHARS (random 36)))))))

  (let loop ()
    ;; generate a random uid until it find an id that doesn't already exists?
    (let ((id (random-id)))
      (if (exists? id) (loop) id))))

;; ---

(define (string->scm value)
  "serialize VALUE with `read` as scheme objects"
  (with-input-from-string value (lambda () (read))))

(define (scm->string value)
  "Write VALUE in a string and return it"
  (with-output-to-string (lambda () (write value))))

;; --

;;; <culturia> is handle over the underlying backing store

(define-record-type* <culturia>
  connection
  session
  ;; <atom> cursors
  atoms  ;; main cursor all the atoms used for direct access via uid
  atoms-append  ;; secondary cursor for insert
  atoms-types
  atoms-type-names
  ;; <arrow> cursor
  arrows
  arrows-append
  arrows-outgoings ;; cursor for fetching outgoings set
  arrows-incomings
  )


(set-record-type-printer! <culturia>
                          (lambda (record port)
                            (format port
                                    "<culturia ~s>"
                                    (culturia-connection record))))

;; ---


(define (culturia-init connection)
  (let ((session (session-open connection)))
    ;; create a main table to store <atom>
    (session-create session
                    "table:atoms"
                    (string-append "key_format=r,"
                                   "value_format=SSS,"
                                   "columns="
                                   "(uid,assoc)"))

    ;; create a main table to store <arrow>
    (session-create session
                    "table:arrows"
                    (string-append "key_format=r,"
                                   "value_format=QQ,"
                                   "columns=(uid,start,end)"))
    ;; this index is useful to traverse outgoing set
    (session-create session "index:arrows:outgoings" "columns=(start)")
    ;; this index is useful to traverse incoming set
    (session-create session "index:arrows:incomings" "columns=(end)")

    (make-culturia connection
                   session
                   ;; <atom> cursors
                   (cursor-open session "table:atoms")
                   (cursor-open session "table:atoms" "append")
                   ;; <arrow> cursor
                   (cursor-open session "table:arrows")
                   (cursor-open session "table:arrows" "append")
                   (cursor-open session "index:arrows:outgoings(uid,end)")
                   (cursor-open session "index:arrows:incomings(uid,start)"))))


(define-public (culturia-open path)
  "Initialize a culturia database at PATH; creating if required the tables and
   indices. Return a <culturia> record."
  (let ((connection (connection-open path "create")))
    (culturia-init connection)))


(define-public (culturia-create path)
  "Create and initialize a culturia database at PATH and return a <culturia>"

  (define (path-exists? path)
    "Return #true if path is a file or directory. #false if it doesn't exists"
    (access? path F_OK))

  (when (path-exists? path)
    (raise "There is already something at ~a. Use (culturia-open path) instead" path))

  (mkdir path)
  (culturia-open path))


(define-public (culturia-close culturia)
  (connection-close (culturia-connection culturia)))


(define-public (culturia-begin culturia)
  (session-transaction-begin (culturia-session culturia)))


(define-public (culturia-commit culturia)
  (session-transaction-commit (culturia-session culturia)))


(define-public (culturia-rollback culturia)
  (session-transaction-rollback (culturia-session culturia)))


(define-syntax-rule (with-transaction culturia e ...)
  (begin
    (culturia-begin culturia)
    e ...
    (culturia-commit culturia)))


(export with-transaction)


;; ---

;;; <atoms>


(define-record-type* <atom> culturia uid assoc)

(export atom-uid atom-assoc)

(define-public (atom-save atom)
  (if (null? (atom-uid))
      ;; insert
      (let ((cursor (culturia-atoms-append (atom-culturia atom))))
        (cursor-value-set cursor (scm->string (atom-assoc atom)))
        (cursor-insert cursor)
        ;; return a new version of the <atom>
        (make-atom culturia (car (cursor-key-ref cursor)) assoc))
      ;; update
      (let ((cursor (culturia-atoms (atom-culturia atom))))
          (cursor-key-set cursor (atom-uid uid))
          (when (not (cursor-search cursor))
            (Oops!))
          (cursor-value-set cursor (scm->string (atom-assoc atom)))
          (cursor-update cursor)
          atom)))


(define-public (culturia-ref culturia)
  (lambda (uid)
    (let ((cursor (culturia-atoms culturia)))
      (cursor-key-set cursor uid)
      (when (not (cursor-search cursor))
        (Oops!))
      (let ((assoc (string->scm (cursor-value-ref cursor))))
        (make-atom culturia uid assoc)))))


(define-public (atom-set atom key value)
  (let* ((assoc (atom-assoc atom))
         (assoc (alist-delete key assoc))
         (assoc (acons key value assoc)))
    (make-atom (atom-culturia atom) (atom-uid atom) assoc)))


(define-public (atom-ref key)
  (lambda (atom)
    (assoc-ref (atom-assoc atom) key)))


(define-public (atom-link! atom other)
  (let ((cursor (culturia-arrows-append (atom-culturia atom))))
    (cursor-value-set cursor (atom-uid atom) (atom-uid other))
    (cursor-insert cursor)))


(define-public (atom-unlink atom other)
  (Oops!))


;; define traversi seed procedures for outgoings and incomings arrows

(define (atom-arrow atom cursor)
  (let ((uid (atom-uid atom)))
    (cursor-key-set cursor uid)
    (if (cursor-search cursor)
        (let loop ((atoms (list)))
          (if (eq? (car (cursor-key-ref cursor)) uid)
              (match (cursor-value-ref cursor)
                ((_ uid)
                 (let ((atoms (cons uid atoms)))
                   (if (cursor-next cursor)
                       (loop atoms)
                       atoms))))
              atoms))
        (list))))


(define-public (atom-outgoings atom)
  "Return a stream of <gremlin> of the outgoings arrows of ATOM"
  (let* ((cursor (culturia-arrows-outgoings (atom-culturia atom)))
         (uids (atom-arrow atom cursor))
         (ref (culturia-ref (atom-culturia atom))))
    (map ref uids)))


(define-public (atom-incomings atom)
  "Return a stream of <gremlin> of the incomings arrows of ATOM"
  (let* ((cursor (culturia-arrows-incomings (atom-culturia atom)))
         (uids (atom-arrow atom cursor))
         (ref (culturia-ref (atom-culturia atom))))
    (map ref uids)))


;; define atom delete

(define (remove-arrows cursor)
  (cursor-key-set cursor)
  (when (cursor-search cursor)
    (let loop ()
      (if (eq? (car (cursor-key-ref cursor)) uid)
          (match (cursor-value-ref cursor)
            ((uid _)
             (cursor-key-set atoms uid)
             (cursor-search atoms)
             (cursor-remove atmos)
             (loop)))))))


(define-public (atom-delete atom)
  (let* ((culturia (atom-culturia atom))
         (atoms (culturia-atoms culturia))
         (arrows (culturia-arrows culturia))
         (outgoings (culturia-arrows-outgoings culturia))
         (incomings (culturia-arrows-incomings culturia)))
    ;; remove atom entry
    (cursor-key-set atoms (atom-uid atom))
    (cursor-remove atoms)
    ;; remove outgoings arrows
    (remove-arrows outgoings)
    (remove-arrows incomings)))


;; ---

;;; traverse framework

;; very much inspired from gremlin
;; http://tinkerpop.incubator.apache.org/docs/3.0.0-incubating/
;;
;; traverser procedures that takes a stream of <gremlin> as input
;; and return another stream of <gremlin> possibly of different type.
;; Most of the time those <gremlin> value is atoms uid ie. integers.
;;
;; traverser procedures are prefixed with ":" character

