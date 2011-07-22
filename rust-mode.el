(require 'cm-mode)
(require 'cc-mode)

(defun rust-electric-brace (arg)
  (interactive "*P")
  (self-insert-command (prefix-numeric-value arg))
  (when (and c-electric-flag
             (not (member (get-text-property (point) 'face)
                          '(font-lock-comment-face font-lock-string-face))))
    (cm-indent)))

(defvar rust-indent-unit 4)
(defvar rust-syntax-table (let ((table (make-syntax-table)))
                            (c-populate-syntax-table table)
                            table))

(add-to-list 'auto-mode-alist '("\\.rs$" . rust-mode))
(add-to-list 'auto-mode-alist '("\\.rc$" . rust-mode))

(defun make-rust-state ()
  (vector 'rust-token-base
          (list (vector 'top (- rust-indent-unit) nil nil nil))
          0
          nil))
(defmacro rust-state-tokenize (x) `(aref ,x 0))
(defmacro rust-state-context (x) `(aref ,x 1))
(defmacro rust-state-indent (x) `(aref ,x 2))
(defmacro rust-state-expect (x) `(aref ,x 3))

(defmacro rust-context-type (x) `(aref ,x 0))
(defmacro rust-context-indent (x) `(aref ,x 1))
(defmacro rust-context-column (x) `(aref ,x 2))
(defmacro rust-context-align (x) `(aref ,x 3))
(defmacro rust-context-info (x) `(aref ,x 4))

(defun rust-push-context (st type &optional align-column)
  (let ((ctx (vector type (rust-state-indent st) align-column (if align-column 'unset nil) nil)))
    (push ctx (rust-state-context st))
    ctx))
(defun rust-pop-context (st)
  (let ((old (pop (rust-state-context st))))
    (setf (rust-state-indent st) (rust-context-indent old))
    old))

(defvar rust-operator-chars "+-/%=<>!*&|@~")
(defvar rust-punc-chars "()[].,{}:;")
(defvar rust-value-keywords
  (let ((table (make-hash-table :test 'equal)))
    (dolist (word '("mod" "type" "resource" "auto" "fn" "pred" "iter" "tag" "obj"))
      (puthash word 'def table))
    (dolist (word '("if" "else" "while" "do" "for" "break" "cont" "put" "ret" "be" "fail" "const"
                    "check" "assert" "claim" "prove" "native" "import" "export" "let" "log" "log_err"))
      (puthash word t table))
    (puthash "alt" 'alt table)
    (dolist (word '("true" "false")) (puthash word 'atom table))
    table))
;; FIXME type-context keywords

(defvar rust-tcat nil "Kludge for multiple returns without consing")

(defmacro rust-eat-re (re)
  `(when (looking-at ,re) (goto-char (match-end 0)) t))

(defvar rust-char-table
  (let ((table (make-char-table 'rust)))
    (macrolet ((def (range &rest body)
                    `(let ((--b (lambda (st) ,@body)))
                       ,@(mapcar (lambda (elt) `(set-char-table-range table ',elt --b))
                                 (if (consp range) range (list range))))))
      (def t (forward-char) nil)
      (def (32 ?\t) (skip-chars-forward " \t") nil)
      (def ?\" (forward-char)
           (rust-push-context st 'string)
           (setf (rust-state-tokenize st) 'rust-token-string)
           (rust-token-string st))
      (def ?\' (forward-char)
           (setf rust-tcat 'atom)
           (let ((is-escape (eq (char-after) ?\\))
                 (start (point)))
             (if (not (rust-eat-until-unescaped ?\'))
                 'font-lock-warning-face
               (if (or is-escape (= (point) (+ start 2)))
                   'font-lock-string-face 'font-lock-warning-face))))
      (def ?/ (forward-char)
           (case (char-after)
             (?/ (end-of-line) 'font-lock-comment-face)
             (?* (forward-char)
                 (rust-push-context st 'comment)
                 (setf (rust-state-tokenize st) 'rust-token-comment)
                 (rust-token-comment st))
             (t (skip-chars-forward rust-operator-chars) (setf rust-tcat 'op) nil)))
      (def ?# (forward-char)
           (cond ((eq (char-after) ?\[) (forward-char) (setf rust-tcat 'open-attr))
                 ((rust-eat-re "[a-z_]+") (setf rust-tcat 'macro)))
           'font-lock-preprocessor-face)
      (def ((?a . ?z) (?A . ?Z) ?_)
           (rust-eat-re "[a-zA-Z_][a-zA-Z0-9_]*")
           (setf rust-tcat 'ident)
           (if (and (eq (char-after) ?:) (eq (char-after (+ (point) 1)) ?:)
                    (not (eq (char-after (+ (point) 2)) ?:)))
               (progn (forward-char 2) 'font-lock-builtin-face)
             (match-string 0)))
      (def ((?0 . ?9))
           (rust-eat-re "0x[0-9a-fA-F]+\\|[0-9]+\\(\\.[0-9]+\\)?\\(e[+\\-]?[0-9]+\\)?")
           (setf rust-tcat 'atom)
           (rust-eat-re "[iuf][0-9]*")
           'font-lock-constant-face)
      (def ?. (forward-char)
           (cond ((rust-eat-re "[0-9]+\\(e[+\\-]?[0-9]+\\)?")
                  (setf rust-tcat 'atom)
                  (rust-eat-re "f[0-9]+")
                  'font-lock-constant-face)
                 (t (setf rust-tcat (char-before)) nil)))
      (def (?\( ?\) ?\[ ?\] ?\{ ?\} ?: ?\; ?,)
           (forward-char)
           (setf rust-tcat (char-before)) nil)
      (def (?+ ?- ?% ?= ?< ?> ?! ?* ?& ?| ?@ ?~)
           (skip-chars-forward rust-operator-chars)
           (setf rust-tcat 'op) nil)
      table)))

(defun rust-token-base (st)
  (funcall (char-table-range rust-char-table (char-after)) st))

(defun rust-eat-until-unescaped (ch)
  (let (escaped)
    (loop
     (let ((cur (char-after)))
       (when (or (eq cur ?\n) (not cur)) (return nil))
       (forward-char)
       (when (and (eq cur ch) (not escaped)) (return t))
       (setf escaped (and (not escaped) (eq cur ?\\)))))))

(defun rust-token-string (st)
  (setf rust-tcat 'atom)
  (when (rust-eat-until-unescaped ?\")
    (setf (rust-state-tokenize st) 'rust-token-base)
    (rust-pop-context st))
  'font-lock-string-face)

(defun rust-token-comment (st)
  (let ((eol (point-at-eol)))
    (loop
     (unless (re-search-forward "\\(/\\*\\)\\|\\(\\*/\\)" eol t)
       (goto-char eol)
       (return))
     (if (match-beginning 1)
         (rust-push-context st 'comment)
       (rust-pop-context st)
       (unless (eq (rust-context-type (car (rust-state-context st))) 'comment)
         (setf (rust-state-tokenize st) 'rust-token-base)
         (return))))
    'font-lock-comment-face))

(defun rust-token (st)
  (let ((cx (car (rust-state-context st))))
    (when (bolp)
      (setf (rust-state-indent st) (current-indentation))
      (when (eq (rust-context-align cx) 'unset)
        (setf (rust-context-align cx) nil)))
    (setf rust-tcat nil)
    (let ((tok (funcall (rust-state-tokenize st) st))
          (cur-cx (rust-context-type cx))
          (is-def nil)
          (expect (rust-state-expect st)))
      (when (stringp tok)
        (let ((kw (gethash tok rust-value-keywords nil)))
          (case kw (def (setf is-def t)) (alt (setf expect 'alt)))
          (setf tok (cond (kw (if (eq kw 'atom) 'font-lock-constant-face 'font-lock-keyword-face))
                          ((eq expect 'def) 'font-lock-function-name-face)
                          (t nil)))))
      (when rust-tcat
        (when (eq (rust-context-align cx) 'unset)
          (setf (rust-context-align cx) t))
        (case rust-tcat
          ((?\; ?: ?,)
           (when (eq cur-cx 'statement) (rust-pop-context st)))
          (?\{
           (when (eq cur-cx 'statement) (rust-pop-context st))
           (let ((is-alt (eq (rust-state-expect st) 'alt))
                 (inside-alt (dolist (cx (rust-state-context st))
                               (when (eq (rust-context-type cx) ?\})
                                 (return (eq (rust-context-info cx) 'alt-outer)))))
                 (newcx (rust-push-context st ?\} (- (current-column) 1))))
             (cond (is-alt (setf expect nil (rust-context-info newcx) 'alt-outer))
                   (inside-alt (setf (rust-context-info newcx) 'alt-inner)))))
          ((?\[ open-attr)
           (let ((newcx (rust-push-context st ?\] (- (current-column) 1))))
             (when (eq rust-tcat 'open-attr)
               (setf (rust-context-info newcx) 'attr))))
          (?\( (rust-push-context st ?\) (- (current-column) 1)))
          (?\} (dolist (close '(statement ?\} statement))
                 (when (eq close cur-cx)
                   (rust-pop-context st)
                   (setf cur-cx (rust-context-type (car (rust-state-context st)))))))
          (t (cond ((eq cur-cx rust-tcat)
                    (when (eq (rust-context-info (rust-pop-context st)) 'attr)
                      (setf tok 'font-lock-preprocessor-face)
                      (when (eq (rust-context-type (car (rust-state-context st))) 'statement)
                        (rust-pop-context st))))
                   ((or (and (eq cur-cx ?\}) (not (eq (rust-context-info cx) 'alt-outer)))
                        (eq cur-cx 'top))
                    (rust-push-context st 'statement)))))
        (setf (rust-state-expect st) (cond (is-def 'def)
                                           ((eq expect 'def) nil)
                                           (t expect))))
      tok)))

(defun rust-indent (st)
  (let* ((cx (let ((head (car (rust-state-context st))))
               (if (and (member (char-after) '(?\{ ?\})) (eq (rust-context-type head) 'statement))
                   (cadr (rust-state-context st)) head)))
         (closing (eq (rust-context-type cx) (char-after)))
         (unit (if (member (rust-context-info cx) '(alt-inner alt-outer))
                   (/ rust-indent-unit 2) rust-indent-unit)))
    (cond ((eq (rust-state-tokenize st) 'rust-token-string) 0)
          ((eq (rust-context-type cx) 'statement)
           (+ (rust-context-indent cx) (if (eq (char-after) ?\}) 0 unit)))
          ((eq (rust-context-align cx) t) (+ (rust-context-column cx) (if closing 0 1)))
          (t (+ (rust-context-indent cx) (if closing 0 unit))))))

(define-derived-mode rust-mode fundamental-mode "Rust"
  "Major mode for editing Rust source files."
  (set-syntax-table rust-syntax-table)
  (setq major-mode 'rust-mode mode-name "Rust")
  (run-hooks 'rust-mode-hook)
  (set (make-local-variable 'indent-tabs-mode) nil)
  (cm-mode (make-cm-mode 'rust-token 'make-rust-state 'copy-sequence 'equal 'rust-indent)))

(define-key rust-mode-map "}" 'rust-electric-brace)
(define-key rust-mode-map "{" 'rust-electric-brace)

(provide 'rust-mode)
