(define-record-type* <culturia>
  connection
  session
  ;; <revision>
  revisions
  revisions-append  ;; secondary cursor for insert
  revisions-names  ;;
  revisions-tree
  ;; <culture>
  cultures
  cultures-append  ;; secondary cursor for insert
  cultures-names  ;; third cursor for name look of egos
  ;; <atom> cursors
  atoms  ;; main cursor all the atoms used for direct access via uid
  atoms-append  ;; secondary cursor for insert
  atoms-revisions
  atoms-cultures
  atoms-names
  atoms-type-names
  ;; <arrow> cursor
  arrows
  arrows-append
  arrows-outgoings ;; cursor for fetching outgoings set
  arrows-incomings
  )

(session-create session
                "table:revisions"
                (string-append "key_format=r,"
                               "value_format=QSS,"
                               "columns=(uid,parent,name,comment)"))

(session-create session
                "table:cultures"
                (string-append "key_format=r,"
                               "value_format=QQSS,"
                               "columns=(uid,revision,parent,name,comment)"))

(session-create session
                "table:atoms"
                (string-append "key_format=r,"
                               "value_format=QQQSSS,"
                               "columns="
                               (string-append "("
                                              "uid,"
                                              "revision,"
                                              "deleted,"
                                              "culture,"
                                              "type,"
                                              "name,"
                                              "data,"
                                              ")")))

(define-record-type* <revision> culturia uid parent name comment path cultures-tree)
(define-record-type* <culture> revision uid parent name comment)


(define (lookup prefix cursor)
  (with-cursor cursor
    (cursor-key-set cursor prefix)
    (if (cursor-search-near cursor)
        (let loop ((atoms (list)))
          ;; make sure it did not go beyond the keys
          ;; we are interested in
          (if (prefix? prefix (cursor-key-ref cursor))
              (let ((atoms (cons (cursor-value-ref cursor) atoms)))
                ;; is there any other key in the hashmap?
                (if (cursor-next cursor)
                    (loop atoms)
                    atoms))))
        (list))))
