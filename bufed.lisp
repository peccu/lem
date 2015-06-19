(in-package :lem)

(define-key *global-keymap* "M-~" 'unmark-buffer)
(defcommand unmark-buffer () ()
  (setf (buffer-modified-p (window-buffer)) nil)
  t)

(defun set-buffer (buffer)
  (let ((old-buf (window-buffer)))
    (setq *prev-buffer* old-buf)
    (setf (buffer-keep-binfo old-buf)
      (list (window-vtop-linum)
        (window-cur-linum)
        (window-cur-col)
        (window-max-col))))
  (setf (window-buffer) buffer)
  (let ((vtop-linum 1)
        (cur-linum 1)
        (cur-col 0)
        (max-col 0))
    (when (buffer-keep-binfo buffer)
      (multiple-value-setq (vtop-linum cur-linum cur-col max-col)
        (apply 'values (buffer-keep-binfo buffer))))
    (setf (window-vtop-linum) vtop-linum)
    (setf (window-cur-linum) cur-linum)
    (setf (window-cur-col) cur-col)
    (setf (window-max-col) max-col)))

(defun head-line-p (window linum)
  (declare (ignore window))
  (values (<= linum 1) (- 1 linum)))

(defun tail-line-p (window linum)
  (let ((nlines (buffer-nlines (window-buffer window))))
    (values (<= nlines linum) (- nlines linum))))

(defun bolp ()
  (zerop (window-cur-col)))

(defun eolp ()
  (= (window-cur-col)
     (buffer-line-length
      (window-buffer)
      (window-cur-linum))))

(defun bobp ()
  (and (head-line-p *current-window* (window-cur-linum))
       (bolp)))

(defun eobp ()
  (and (tail-line-p
        *current-window*
        (window-cur-linum))
       (eolp)))

(defun insert-char (c n)
  (dotimes (_ n t)
    (buffer-insert-char
     (window-buffer)
     (window-cur-linum)
     (window-cur-col)
     c)
    (next-char 1)))

(defun insert-string (str)
  (do ((rest (split-string str #\newline) (cdr rest)))
      ((null rest))
    (buffer-insert-line
     (window-buffer)
     (window-cur-linum)
     (window-cur-col)
     (car rest))
    (next-char (length (car rest)))
    (when (cdr rest)
      (insert-newline 1))))

(define-key *global-keymap* "C-j" 'insert-newline)
(defcommand insert-newline (n) ("p")
  (dotimes (_ n t)
    (buffer-insert-newline (window-buffer)
                            (window-cur-linum)
                            (window-cur-col))
    (next-line 1)))

(define-key *global-keymap* "C-d" 'delete-char)
(defcommand delete-char (n) ("P")
  (cond
   ((null n)
    (buffer-delete-char
     (window-buffer)
     (window-cur-linum)
     (window-cur-col)
     1))
   ((minusp n)
    (backward-delete-char (- n)))
   (t
    (multiple-value-bind (result str)
        (buffer-delete-char
         (window-buffer)
         (window-cur-linum)
         (window-cur-col)
         n)
      (with-kill ()
        (kill-push str))
      result))))

(define-key *global-keymap* "C-h" 'backward-delete-char)
(defcommand backward-delete-char (n) ("p")
  (if (minusp n)
    (delete-char (- n))
    (when (prev-char n)
      (delete-char n))))

(defun goto-column (col)
  (setf (window-cur-col) col)
  (setf (window-max-col) col))

(define-key *global-keymap* "C-a" 'beginning-of-line)
(defcommand beginning-of-line () ()
  (goto-column 0)
  t)

(define-key *global-keymap* "C-e" 'end-of-line)
(defcommand end-of-line () ()
  (goto-column (buffer-line-length
                (window-buffer)
                (window-cur-linum)))
  t)

(defun %buffer-adjust-col (arg)
  (if arg
    (beginning-of-line)
    (setf (window-cur-col)
          (min (window-max-col)
               (buffer-line-length
                (window-buffer)
                (window-cur-linum))))))

(define-key *global-keymap* "C-n" 'next-line)
(defcommand next-line (&optional n) ("P")
  (if (and n (minusp n))
    (prev-line (- n))
    (if (dotimes (_ (or n 1) t)
          (if (tail-line-p *current-window* (window-cur-linum))
            (return)
            (incf (window-cur-linum))))
      (progn (%buffer-adjust-col n) t)
      (progn (end-of-line) t))))

(define-key *global-keymap* "C-p" 'prev-line)
(defcommand prev-line (&optional n) ("P")
  (if (and n (minusp n))
    (next-line (- n))
    (if (dotimes (_ (or n 1) t)
          (if (head-line-p *current-window* (window-cur-linum))
            (return)
            (decf (window-cur-linum))))
      (progn (%buffer-adjust-col n) t)
      (progn (beginning-of-line) nil))))

(define-key *global-keymap* "C-f" 'next-char)
(defcommand next-char (&optional (n 1)) ("p")
  (if (minusp n)
    (prev-char (- n))
    (dotimes (_ n t)
      (cond
       ((eobp)
        (return nil))
       ((eolp)
        (next-line 1))
       (t
        (goto-column (1+ (window-cur-col))))))))

(define-key *global-keymap* "C-b" 'prev-char)
(defcommand prev-char (&optional (n 1)) ("p")
  (if (minusp n)
    (next-char (- n))
    (dotimes (_ n t)
      (cond
       ((bobp)
        (return nil))
       ((bolp)
        (prev-line 1)
        (end-of-line))
       (t
        (goto-column (1- (window-cur-col))))))))

(define-key *global-keymap* "C-@" 'mark-set)
(defcommand mark-set () ()
  (let ((buffer (window-buffer)))
    (setf (buffer-mark-linum buffer)
      (window-cur-linum))
    (setf (buffer-mark-col buffer)
      (window-cur-col))
    (mb-write "Mark set")
    t))

(define-key *global-keymap* "C-xC-x" 'exchange-point-mark)
(defcommand exchange-point-mark () ()
  (let ((buffer (window-buffer)))
    (if (null (buffer-mark-linum buffer))
      (progn
       (mb-write "Not mark in this buffer")
       nil)
      (progn
       (psetf
        (window-cur-linum) (buffer-mark-linum buffer)
        (window-cur-col) (buffer-mark-col buffer)
        (buffer-mark-linum buffer) (window-cur-linum)
        (buffer-mark-col buffer) (window-cur-col))
       (setf (window-max-col) (buffer-mark-col buffer))
       t))))

(defun current-line-string ()
  (buffer-get-line-string
   (window-buffer)
   (window-cur-linum)))