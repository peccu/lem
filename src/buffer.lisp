(in-package :lem)

(export '(*undo-limit*
          buffer
          buffer-p
          buffer-name
          buffer-filename
          buffer-modified-p
          buffer-read-only-p
          buffer-enable-undo-p
          buffer-major-mode
          buffer-minor-modes
          buffer-mark-p
          buffer-nlines
          buffer-overlays
          buffer-truncate-lines
          buffer-enable-undo
          buffer-disable-undo
          buffer-put-property
          buffer-get-char
          buffer-line-length
          buffer-line-string-with-attributes
          buffer-line-string
          buffer-end-line-p
          map-buffer-lines
          buffer-take-lines
          buffer-insert-char
          buffer-insert-newline
          buffer-insert-line
          buffer-delete-char
          buffer-erase
          buffer-rename
          buffer-directory
          buffer-undo-boundary
          get-bvar
          clear-buffer-variables
          buffer-add-delete-hook))

(defstruct (line (:constructor %make-line))
  prev
  next
  str
  plist
  %scan-cached-p
  %symbol-lifetimes
  %region)

(defmethod print-object ((object line) stream)
  (print-unreadable-object (object stream :identity t)
    (format stream "LINE: string: ~S, plist: ~S"
            (line-str object)
            (line-plist object))))

(defun make-line (prev next str)
  (let ((line (%make-line :next next
                          :prev prev
                          :str str)))
    (when next
      (setf (line-prev next) line))
    (when prev
      (setf (line-next prev) line))
    line))

(defun line-length (line)
  (length (line-str line)))

(defun line-add-property (line start end key value)
  (push (list start end value)
        (getf (line-plist line) key)))

(defun line-clear-property (line key)
  (setf (getf (line-plist line) key) nil))

(defun line-search-property (line key pos)
  (loop :for (start end value) :in (getf (line-plist line) key)
        :do (when (<= start pos (1- end))
              (return value))))

(defun line-property-insert-pos (line pos offset)
  (loop :for values :in (cdr (line-plist line)) :by #'cddr
        :do (dolist (v values)
              (destructuring-bind (start end value) v
                (declare (ignore value))
                (cond ((<= pos start)
                       (incf (first v) offset)
                       (incf (second v) offset))
                      ((< start pos end)
                       (incf (second v) offset))
                      ((< pos end)
                       (incf (second v) offset)))))))

(defun line-property-insert-newline (line next-line pos)
  (let ((new-plist '()))
    (loop :for plist-rest :on (line-plist line) :by #'cddr
          :do (let ((new-values '()))
                (setf (cadr plist-rest)
                      (loop :for elt :in (cadr plist-rest)
                            :for (start end value) := elt
                            :if (<= pos start)
                            :do (push (list (- start pos) (- end pos) value) new-values)
                            :else :if (<= pos end)
                            :collect (list start pos value)
                            :else
                            :collect elt))
                (unless (null new-values)
                  (setf (getf new-plist (car plist-rest)) new-values))))
    (setf (line-plist next-line) new-plist)))

(defun line-property-delete-pos (line pos n)
  (loop :for plist-rest :on (line-plist line) :by #'cddr
        :do (setf (cadr plist-rest)
                  (loop :for elt :in (cadr plist-rest)
                        :for (start end value) := elt
                        :if (<= pos start end (+ pos n))
                        :do (progn)
                        :else :if (<= pos (+ pos n) start)
                        :collect (list (- start n) (- end n) value)
                        :else :if (< pos start (+ pos n))
                        :collect (list pos (- end n) value)
                        :else :if (<= start pos (+ pos n) end)
                        :collect (list start (- end n) value)
                        :else :if (<= start pos end (+ pos n))
                        :collect (list start pos value)
                        :else
                        :collect elt))))

(defun line-property-delete-line (line pos)
  (loop :for plist-rest :on (line-plist line) :by #'cddr
        :do (setf (cadr plist-rest)
                  (loop :for elt :in (cadr plist-rest)
                        :for (start end value) := elt
                        :if (<= pos start)
                        :do (progn)
                        :else :if (<= pos end)
                        :collect (list start pos value)
                        :else
                        :collect elt
                        ))))

(defun line-free (line)
  (when (line-prev line)
    (setf (line-next (line-prev line))
          (line-next line)))
  (when (line-next line)
    (setf (line-prev (line-next line))
          (line-prev line)))
  (setf (line-prev line) nil
        (line-next line) nil
        (line-str line) nil))

(defun line-step-n (line n step-f)
  (do ((l line (funcall step-f l))
       (i 0 (1+ i)))
      ((= i n) l)))

(defun line-forward-n (line n)
  (line-step-n line n 'line-next))

(defun line-backward-n (line n)
  (line-step-n line n 'line-prev))

(define-class buffer () (current-buffer)
  name
  filename
  modified-p
  read-only-p
  enable-undo-p
  major-mode
  minor-modes
  head-line
  tail-line
  cache-line
  cache-linum
  mark-p
  mark-overlay
  mark-marker
  keep-binfo
  nlines
  undo-size
  undo-stack
  redo-stack
  overlays
  markers
  truncate-lines
  external-format
  last-write-date
  delete-hooks
  variables)

(defvar *undo-modes* '(:edit :undo :redo))
(defvar *undo-mode* :edit)
(defvar *undo-limit* 100000)

(defun make-buffer (name &key filename read-only-p (enable-undo-p t))
  (let ((buffer (make-instance 'buffer
                               :name name
                               :filename filename
                               :read-only-p read-only-p
                               :enable-undo-p enable-undo-p
                               :major-mode 'fundamental-mode)))
    (buffer-reset buffer)
    (setf (buffer-undo-size buffer) 0)
    (setf (buffer-undo-stack buffer) nil)
    (setf (buffer-redo-stack buffer) nil)
    (setf (buffer-markers buffer) nil)
    (setf (buffer-truncate-lines buffer) t)
    (setf (buffer-variables buffer) (make-hash-table :test 'equal))
    (add-buffer buffer)
    buffer))

(defun buffer-reset (buffer)
  (let ((line (make-line nil nil "")))
    (setf (buffer-head-line buffer) line)
    (setf (buffer-tail-line buffer) line)
    (setf (buffer-cache-line buffer) line)
    (setf (buffer-cache-linum buffer) 1)
    (setf (buffer-mark-p buffer) nil)
    (setf (buffer-mark-overlay buffer) nil)
    (setf (buffer-mark-marker buffer) nil)
    (setf (buffer-keep-binfo buffer) nil)
    (setf (buffer-nlines buffer) 1)
    (setf (buffer-overlays buffer) nil)))

(defun buffer-p (x)
  (typep x 'buffer))

(defmethod print-object ((buffer buffer) stream)
  (format stream "#<BUFFER ~a ~a>"
          (buffer-name buffer)
          (buffer-filename buffer)))

(defun buffer-enable-undo (buffer)
  (setf (buffer-enable-undo-p buffer) t)
  nil)

(defun buffer-disable-undo (buffer)
  (setf (buffer-enable-undo-p buffer) nil)
  (setf (buffer-undo-size buffer) 0)
  (setf (buffer-undo-stack buffer) nil)
  (setf (buffer-redo-stack buffer) nil)
  nil)

(defun buffer-unmark (buffer)
  (setf (buffer-modified-p buffer) nil))

(defun buffer-apply-line (apply-fn buffer linum start-charpos end-charpos args)
  (let ((line (buffer-get-line buffer linum)))
    (apply apply-fn
           line
           (or start-charpos 0)
           (or end-charpos (line-length line))
           args)))

(defun buffer-apply-lines (apply-fn buffer start end &rest args)
  (with-points (((start-linum start-charpos) start)
                ((end-linum end-charpos) end))
    (cond ((= start-linum end-linum)
           (buffer-apply-line apply-fn buffer start-linum start-charpos end-charpos args))
          (t
           (buffer-apply-line apply-fn buffer start-linum start-charpos nil args)
           (buffer-apply-line apply-fn buffer end-linum 0 end-charpos args)
           (loop :for linum :from (1+ start-linum) :below end-linum
                 :do (buffer-apply-line apply-fn buffer linum nil nil args))))))

(defun buffer-put-property (buffer start end key value)
  (buffer-apply-lines #'line-add-property buffer start end key value))

(defun buffer-add-overlay (buffer overlay)
  (push overlay (buffer-overlays buffer)))

(defun buffer-delete-overlay (buffer overlay)
  (setf (buffer-overlays buffer)
        (delete overlay (buffer-overlays buffer))))

(defun buffer-add-marker (buffer marker)
  (push marker (buffer-markers buffer)))

(defun buffer-delete-marker (buffer marker)
  (setf (buffer-markers buffer)
        (delete marker (buffer-markers buffer))))

(defun buffer-mark-cancel (buffer)
  (when (buffer-mark-p buffer)
    (setf (buffer-mark-p buffer) nil)
    (delete-overlay (buffer-mark-overlay buffer))))

(defun buffer-end-point (buffer)
  (make-point (buffer-nlines buffer)
              (line-length (buffer-tail-line buffer))))

(defun %buffer-get-line (buffer linum)
  (cond
   ((= linum (buffer-cache-linum buffer))
    (buffer-cache-line buffer))
   ((> linum (buffer-cache-linum buffer))
    (if (< (- linum (buffer-cache-linum buffer))
           (- (buffer-nlines buffer) linum))
        (line-forward-n
         (buffer-cache-line buffer)
         (- linum (buffer-cache-linum buffer)))
        (line-backward-n
         (buffer-tail-line buffer)
         (- (buffer-nlines buffer) linum))))
   (t
    (if (< (1- linum)
           (- (buffer-cache-linum buffer) linum))
        (line-forward-n
         (buffer-head-line buffer)
         (1- linum))
        (line-backward-n
         (buffer-cache-line buffer)
         (- (buffer-cache-linum buffer) linum))))))

(defun buffer-get-line (buffer linum)
  (assert (<= 1 linum))
  (assert (<= linum (buffer-nlines buffer)))
  (let ((line (%buffer-get-line buffer linum)))
    (setf (buffer-cache-linum buffer) linum)
    (setf (buffer-cache-line buffer) line)
    line))

(defun buffer-get-char (buffer linum charpos)
  (let ((line (buffer-get-line buffer linum)))
    (when (line-p line)
      (let* ((str (line-str line))
             (len (length str)))
        (cond
          ((<= 0 charpos (1- len))
           (char str charpos))
          ((= charpos len)
           #\newline))))))

(defun buffer-line-length (buffer linum)
  (line-length (buffer-get-line buffer linum)))

(defun buffer-line-string-with-attributes (buffer linum)
  (let ((line (buffer-get-line buffer linum)))
    (when (line-p line)
      (values (line-str line)
              (getf (line-plist line) :attribute)))))

(defun buffer-line-string (buffer linum)
  (let ((line (buffer-get-line buffer linum)))
    (when (line-p line)
      (line-str line))))

(defun buffer-end-line-p (buffer linum)
  (let ((line (buffer-get-line buffer linum)))
    (not (line-next line))))

(defun map-buffer (fn buffer &optional start-linum)
  (do ((line (if start-linum
                 (buffer-get-line buffer start-linum)
                 (buffer-head-line buffer))
             (line-next line))
       (linum (or start-linum 1) (1+ linum)))
      ((null line))
    (funcall fn line linum)))

(defun map-buffer-lines (fn buffer &optional start end)
  (let ((head-line
         (if start
             (buffer-get-line buffer start)
             (buffer-head-line buffer))))
    (unless end
      (setq end (buffer-nlines buffer)))
    (do ((line head-line (line-next line))
         (i (or start 1) (1+ i)))
        ((or (null line) (< end i)))
      (funcall fn
               (line-str line)
               (not (line-next line))
               i))))

(defun buffer-take-lines (buffer &optional linum len)
  (unless linum
    (setq linum 1))
  (unless len
    (setq len (buffer-nlines buffer)))
  (let ((strings))
    (map-buffer-lines
     #'(lambda (str eof-p linum)
         (declare (ignore eof-p linum))
         (push str strings))
     buffer
     linum
     (+ linum len -1))
    (nreverse strings)))

(defun buffer-update-mark-overlay (buffer)
  (when (buffer-mark-p buffer)
    (let (start
          end
          (mark-point (marker-point (buffer-mark-marker buffer)))
          (cur-point (current-point)))
      (if (point< mark-point cur-point)
          (setq start mark-point
                end cur-point)
          (setq start cur-point
                end mark-point))
      (when (buffer-mark-overlay buffer)
        (delete-overlay (buffer-mark-overlay buffer)))
      (setf (buffer-mark-overlay buffer)
            (make-overlay start end *mark-overlay-attribute*)))))

(defun check-read-only (buffer)
  (when (buffer-read-only-p buffer)
    (error 'readonly)))

(defun buffer-modify (buffer)
  (setf (buffer-modified-p buffer)
        (if (buffer-modified-p buffer)
            (1+ (mod (buffer-modified-p buffer)
                     #.(floor most-positive-fixnum 2)))
            0))
  (buffer-mark-cancel buffer))

(defmacro with-buffer-modify (buffer &body body)
  `(progn
     (check-read-only ,buffer)
     (prog1 (progn ,@body)
       (buffer-modify ,buffer))))

(defun push-undo-stack (buffer elt)
  (cond ((<= (+ *undo-limit* (floor (* *undo-limit* 0.3)))
             (buffer-undo-size buffer))
         (setf (buffer-undo-stack buffer)
               (subseq (buffer-undo-stack buffer)
                       0
                       *undo-limit*))
         (setf (buffer-undo-size buffer)
               (1+ (length (buffer-undo-stack buffer)))))
        (t
         (incf (buffer-undo-size buffer))))
  (push elt (buffer-undo-stack buffer)))

(defun push-redo-stack (buffer elt)
  (push elt (buffer-redo-stack buffer)))

(defmacro with-push-undo ((buffer) &body body)
  (let ((gmark-marker (gensym)))
    `(when (and (buffer-enable-undo-p ,buffer)
                (not (ghost-buffer-p ,buffer)))
       (let ((,gmark-marker (buffer-mark-marker ,buffer)))
         (let ((elt #'(lambda ()
                        (setf (buffer-mark-marker ,buffer) ,gmark-marker)
                        ,@body)))
           (ecase *undo-mode*
             (:edit
              (push-undo-stack ,buffer elt)
              (setf (buffer-redo-stack ,buffer) nil))
             (:redo
              (push-undo-stack ,buffer elt))
             (:undo
              (push-redo-stack ,buffer elt))))))))

(defun buffer-insert-char (buffer linum pos c)
  (cond ((char= c #\newline)
         (buffer-insert-newline buffer linum pos))
        (t
         (with-buffer-modify buffer
           (with-push-undo (buffer)
             (buffer-delete-char buffer linum pos 1)
             (make-point linum pos))
           (let ((line (buffer-get-line buffer linum)))
             (setf (line-%scan-cached-p line) nil)
             (line-property-insert-pos line pos 1)
             (dolist (marker (buffer-markers buffer))
               (when (and (= linum (marker-linum marker))
                          (if (marker-insertion-type marker)
                              (<= pos (marker-charpos marker))
                              (< pos (marker-charpos marker))))
                 (incf (marker-charpos marker))))
             (setf (line-str line)
                   (concatenate 'string
                                (subseq (line-str line) 0 pos)
                                (string c)
                                (subseq (line-str line) pos)))))))
  t)

(defun buffer-insert-newline (buffer linum pos)
  (with-buffer-modify buffer
    (with-push-undo (buffer)
      (buffer-delete-char buffer linum pos 1)
      (make-point linum pos))
    (dolist (marker (buffer-markers buffer))
      (cond
        ((and (= (marker-linum marker) linum)
              (if (marker-insertion-type marker)
                  (<= pos (marker-charpos marker))
                  (< pos (marker-charpos marker))))
         (incf (marker-linum marker))
         (decf (marker-charpos marker) pos))
        ((< linum (marker-linum marker))
         (incf (marker-linum marker)))))
    (let* ((line (buffer-get-line buffer linum))
           (newline
            (make-line line
                       (line-next line)
                       (subseq (line-str line) pos))))
        (setf (line-%scan-cached-p line) nil)
        (line-property-insert-newline line newline pos)
        (when (eq line (buffer-tail-line buffer))
          (setf (buffer-tail-line buffer) newline))
        (setf (line-str line)
              (subseq (line-str line) 0 pos)))
    (incf (buffer-nlines buffer)))
  t)

(defun buffer-insert-line (buffer linum pos str)
  (with-buffer-modify buffer
    (let ((line (buffer-get-line buffer linum)))
      (setf (line-%scan-cached-p line) nil)
      (line-property-insert-pos line pos (length str))
      (with-push-undo (buffer)
        (buffer-delete-char buffer linum pos (length str))
        (make-point linum pos))
      (dolist (marker (buffer-markers buffer))
        (when (and (= linum (marker-linum marker))
                   (if (marker-insertion-type marker)
                       (<= pos (marker-charpos marker))
                       (< pos (marker-charpos marker))))
          (incf (marker-charpos marker) (length str))))
      (setf (line-str line)
            (concatenate 'string
                         (subseq (line-str line) 0 pos)
                         str
                         (subseq (line-str line) pos)))))
  t)

(defun buffer-delete-char (buffer linum pos n)
  (with-buffer-modify buffer
    (let ((line (buffer-get-line buffer linum))
          (del-lines (list "")))
      (setf (line-%scan-cached-p line) nil)
      (loop while (or (eq n t) (plusp n)) do
        (cond
          ((and (not (eq n t))
                (<= n (- (length (line-str line)) pos)))
           (line-property-delete-pos line pos n)
           (dolist (marker (buffer-markers buffer))
             (when (and (= linum (marker-linum marker))
                        (< pos (marker-charpos marker)))
               (setf (marker-charpos marker)
                     (if (> pos (- (marker-charpos marker) n))
                         pos
                         (- (marker-charpos marker) n)))))
           (setf (car del-lines)
                 (concatenate 'string
                              (car del-lines)
                              (subseq (line-str line) pos (+ pos n))))
           (setf (line-str line)
                 (concatenate 'string
                              (subseq (line-str line) 0 pos)
                              (subseq (line-str line) (+ pos n))))
           (return))
          (t
           (line-property-delete-line line pos)
           (dolist (marker (buffer-markers buffer))
             (cond
               ((and (= linum (marker-linum marker))
                     (< pos (marker-charpos marker)))
                (setf (marker-charpos marker) pos))
               ((< linum (marker-linum marker))
                (decf (marker-linum marker)))))
           (setf (car del-lines)
                 (concatenate 'string
                              (car del-lines)
                              (subseq (line-str line) pos)))
           (unless (line-next line)
             (return))
           (push "" del-lines)
           (unless (eq n t)
             (decf n (1+ (- (length (line-str line)) pos))))
           (decf (buffer-nlines buffer))
           (setf (line-str line)
                 (concatenate 'string
                              (subseq (line-str line) 0 pos)
                              (line-str (line-next line))))
           (when (eq (line-next line)
                     (buffer-tail-line buffer))
             (setf (buffer-tail-line buffer) line))
           (line-free (line-next line)))))
      (setq del-lines (nreverse del-lines))
      (with-push-undo (buffer)
        (let ((linum linum)
              (pos pos))
          (do ((rest del-lines (cdr rest)))
              ((null rest))
            (buffer-insert-line buffer linum pos (car rest))
            (when (cdr rest)
              (buffer-insert-newline buffer linum
                                     (+ pos (length (car rest))))
              (incf linum)
              (setq pos 0)))
          (make-point linum pos)))
      del-lines)))

(defun buffer-erase (&optional (buffer (current-buffer)))
  (dolist (marker (buffer-markers buffer))
    (setf (marker-point marker) (make-point 1 0)))
  (buffer-delete-char buffer 1 0 t)
  (buffer-reset buffer)
  t)

(defun buffer-rename (buffer name)
  (check-type buffer buffer)
  (check-type name string)
  (when (get-buffer name)
    (editor-error "Buffer name `~A' is in use" name))
  (setf (buffer-name buffer) name))

(defun buffer-have-file-p (buffer)
  (and (buffer-filename buffer)
       (uiop:file-pathname-p (buffer-filename buffer))))

(defun buffer-directory (&optional (buffer (current-buffer)))
  (if (buffer-filename buffer)
      (directory-namestring
       (buffer-filename buffer))
      (namestring (uiop:getcwd))))

(defun buffer-undo-1 (buffer)
  (let ((elt (pop (buffer-undo-stack buffer))))
    (when elt
      (let ((*undo-mode* :undo))
        (unless (eq elt :separator)
          (decf (buffer-undo-size buffer))
          (funcall elt))))))

(defun buffer-undo (buffer)
  (push :separator (buffer-redo-stack buffer))
  (when (eq :separator (car (buffer-undo-stack buffer)))
    (pop (buffer-undo-stack buffer)))
  (let ((point nil))
    (loop :for result := (buffer-undo-1 buffer)
          :while result
          :do (setf point result))
    (unless point
      (assert (eq :separator (car (buffer-redo-stack buffer))))
      (pop (buffer-redo-stack buffer)))
    point))

(defun buffer-redo-1 (buffer)
  (let ((elt (pop (buffer-redo-stack buffer))))
    (when elt
      (let ((*undo-mode* :redo))
        (unless (eq elt :separator)
          (funcall elt))))))

(defun buffer-redo (buffer)
  (push :separator (buffer-undo-stack buffer))
  (let ((point nil))
    (loop :for result := (buffer-redo-1 buffer)
          :while result
          :do (setf point result))
    (unless point
      (assert (eq :separator (car (buffer-undo-stack buffer))))
      (pop (buffer-undo-stack buffer)))
    point))

(defun buffer-undo-boundary (&optional (buffer (current-buffer)))
  (unless (eq :separator (car (buffer-undo-stack buffer)))
    (push :separator (buffer-undo-stack buffer))))

(defun get-bvar (name &key (buffer (current-buffer)) default)
  (multiple-value-bind (value foundp)
      (gethash name (buffer-variables buffer))
    (if foundp value default)))

(defun (setf get-bvar) (value name &key (buffer (current-buffer)) default)
  (declare (ignore default))
  (setf (gethash name (buffer-variables buffer)) value))

(defun clear-buffer-variables (&key (buffer (current-buffer)))
  (clrhash (buffer-variables buffer)))

(defun buffer-add-delete-hook (buffer fn)
  (push fn (buffer-delete-hooks buffer))
  fn)
