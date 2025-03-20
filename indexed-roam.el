;;; indexed-roam.el --- Make data like org-roam does -*- lexical-binding: t; -*-

;; Copyright (C) 2025 Martin Edström

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; A submodule with two purposes

;; 1. make Indexed aware of ROAM_ALIASES and ROAM_REFS
;; 2. make a SQL database

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'indexed)
(require 'sqlite)
(require 'sqlite-mode)


;;; Aliases and refs support

(defvar indexed-roam--work-buf nil)
(defvar indexed-roam--ref<>id (make-hash-table :test 'equal))
(defvar indexed-roam--id<>refs (make-hash-table :test 'equal))
(defvar indexed-roam--ref<>type (make-hash-table :test 'equal)) ;; REVIEW: weird

(defun indexed-roam-refs (entry)
  "Property ROAM_REFS in ENTRY, properly split."
  (gethash (indexed-id entry) indexed-roam--id<>refs))

(defun indexed-roam-reflinks-to (entry)
  "All links that point to a member of ENTRY\\='s ROAM_REFS."
  (cl-loop for ref in (indexed-roam-refs entry)
           append (gethash ref indexed--dest<>links)))

(defun indexed-roam-aliases (entry)
  "Property ROAM_ALIASES in ENTRY, properly split."
  (when-let* ((aliases (indexed-property "ROAM_ALIASES" entry)))
    (split-string-and-unquote aliases)))

(defun indexed-roam--wipe-lisp-tables (_)
  (clrhash indexed-roam--ref<>id)
  (clrhash indexed-roam--id<>refs))

(defun indexed-roam--record-aliases-refs (entry)
  "Add any ENTRY aliases to `indexed--title<>id'."
  (when-let* ((id (indexed-id entry)))
    (dolist (alias (indexed-roam-aliases entry))
      ;; Include aliases in the collision-checks
      (when-let* ((other-id (gethash alias indexed--title<>id)))
        (unless (string= id other-id)
          (push (list (format-time-string "%H:%M") alias id other-id)
                indexed--title-collisions)))
      (puthash alias id indexed--title<>id))
    (when-let* ((refs (indexed-roam-split-refs-field
                       (indexed-property "ROAM_REFS" entry))))
      (puthash id refs indexed-roam--id<>refs)
      (dolist (ref refs)
        (puthash ref id indexed-roam--ref<>id)))))

(defun indexed-roam--forget-aliases-refs (entry)
  (dolist (ref (indexed-roam-refs entry))
    (dolist (id (gethash ref indexed-roam--ref<>id))
      (remhash id indexed-roam--id<>refs))
    (remhash ref indexed-roam--ref<>id))
  (dolist (alias (indexed-roam-aliases entry))
    (remhash alias indexed--title<>id)))

;; Autoload due to `indexed-orgdb-prop-splitters'.
;;;###autoload
(defun indexed-roam-split-refs-field (roam-refs)
  "Split a ROAM-REFS field correctly.
What this means?  See indexed-test.el."
  (when roam-refs
    (with-current-buffer (get-buffer-create " *indexed-throwaway*" t)
      (erase-buffer)
      (insert roam-refs)
      (goto-char 1)
      (let (links beg end colon-pos)
        ;; Extract all [[bracketed links]]
        (while (search-forward "[[" nil t)
          (setq beg (match-beginning 0))
          (if (setq end (search-forward "]]" nil t))
              (progn
                (goto-char beg)
                (push (buffer-substring (+ 2 beg) (1- (search-forward "]")))
                      links)
                (delete-region beg end))
            (error "Missing close-bracket in ROAM_REFS property %s" roam-refs)))
        ;; Return merged list
        (cl-loop
         for link? in (append links (split-string-and-unquote (buffer-string)))
         ;; @citekey or &citekey
         if (string-match (rx (or bol (any ";:"))
                              (group (any "@&")
                                     (+ (not (any " ;]")))))
                          link?)
         ;; Replace & with @
         collect (let ((path (substring (match-string 1 link?) 1)))
                   (puthash path nil indexed-roam--ref<>type)
                   (concat "@" path))
         ;; Some sort of uri://path
         else when (setq colon-pos (string-search ":" link?))
         collect (let ((path (string-replace
                              "%20" " "
                              (substring link? (1+ colon-pos)))))
                   ;; Remember the uri: prefix for pretty completions
                   (puthash path (substring link? 0 colon-pos)
                            indexed-roam--ref<>type)
                   ;; .. but the actual ref is just the //path
                   path))))))


;;; Mode

(setq my-db-connection (emacsql-sqlite-open org-roam-db-location))
(emacsql my-db-connection [:select * :from files])

(setq indexed-roam-db-location org-roam-db-location)
(org-roam-db-query [:select * :from files])

(defcustom indexed-roam-db-location nil
  "If non-nil, a file name to write the DB to.
Overwrites any file previously there."
  :type 'boolean
  :group 'indexed
  :set (lambda (sym val)
         (prog1 (set-default sym val)
           (indexed-roam--mk-db))))

(defvar indexed-roam--connection nil
  "A SQLite handle.")

(defun indexed-roam--mk-db (&rest _)
  "Close current `indexed-roam--connection' and populate a new one."
  (ignore-errors (sqlite-close indexed-roam--connection))
  (indexed-roam))

;;;###autoload
(define-minor-mode indexed-roam-mode
  "Add awareness of ROAM_ALIASES and ROAM_REFS and make the `indexed-roam' DB."
  :global t
  :group 'indexed
  (if indexed-roam-mode
      (progn
        (add-hook 'indexed-record-entry-functions #'indexed-roam--record-aliases-refs -5)
        (add-hook 'indexed-forget-entry-functions #'indexed-roam--forget-aliases-refs)
        (add-hook 'indexed-post-incremental-update-functions #'indexed-roam--update-db)
        (add-hook 'indexed-post-full-reset-functions #'indexed-roam--mk-db)
        (indexed--scan-full))
    (remove-hook 'indexed-record-entry-functions #'indexed-roam--record-aliases-refs)
    (remove-hook 'indexed-forget-entry-functions #'indexed-roam--forget-aliases-refs)
    (remove-hook 'indexed-post-incremental-update-functions #'indexed-roam--update-db)
    (remove-hook 'indexed-post-full-reset-functions #'indexed-roam--mk-db)))


;;; Database

;;;###autoload
(defun indexed-roam (&optional sql &rest args)
  "Return the SQLite handle to the org-roam-like database.
Each call checks if it is alive, and renews if not.

If arguments SQL and ARGS provided, pass to `sqlite-select'."
  (unless indexed-roam-mode
    (error "Enable `indexed-roam-mode' to use `indexed-roam'"))
  (or (ignore-errors (sqlite-pragma indexed-roam--connection "im_still_here"))
      (setq indexed-roam--connection (indexed-roam--open-new-db
                                      indexed-roam-db-location)))
  (if sql
      (sqlite-select indexed-roam--connection sql args)
    indexed-roam--connection))

(defun indexed-roam--open-new-db (&optional loc)
  "Generate a new database and return a connection-handle to it.
Shape it according to org-roam schemata and pre-populate it with data.

Normally, this creates a diskless database.  With optional file path
LOC, write the database as a file to LOC."
  (let ((T (current-time))
        (name (or loc "SQLite DB"))
        (db (progn (when (file-exists-p loc)
                     (delete-file loc))
                   (sqlite-open loc))))
    (indexed-roam--configure db)
    (indexed-roam--populate-usably-for-emacsql db (indexed-roam--mk-rows))
    (when indexed--next-message
      (setq indexed--next-message
            (concat indexed--next-message
                    (format " (+ %.2fs writing %s)"
                            (float-time (time-since T)) name))))
    db))

(defun indexed-roam--configure (db)
  "Set up tables, schemata and PRAGMA settings in DB."
  (sqlite-execute db "PRAGMA user_version = 19;")
  (sqlite-execute db "PRAGMA foreign_keys = on;")
  ;; Note to devs: try M-x `indexed-roam--insert-schemata-atpt'
  (mapc
   (lambda (query) (sqlite-execute db query))
   '("CREATE TABLE files (
	file UNIQUE PRIMARY KEY,
	title,
	hash NOT NULL,
	atime NOT NULL,
	mtime NOT NULL
);"
     "CREATE TABLE nodes (
	id NOT NULL PRIMARY KEY,
	file NOT NULL,
	level NOT NULL,
	pos NOT NULL,
	todo,
	priority,
	scheduled text,
	deadline text,
	title,
	properties,
	olp,
	FOREIGN KEY (file) REFERENCES files (file) ON DELETE CASCADE
);"
     "CREATE TABLE aliases (
	node_id NOT NULL,
	alias,
	FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE
);"
     "CREATE TABLE citations (
	node_id NOT NULL,
	cite_key NOT NULL,
	pos NOT NULL,
	properties,
	FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE
);"
     "CREATE TABLE refs (
	node_id NOT NULL,
	ref NOT NULL,
	type NOT NULL,
	FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE
);"
     "CREATE TABLE tags (
	node_id NOT NULL,
	tag,
	FOREIGN KEY (node_id) REFERENCES nodes (id) ON DELETE CASCADE
);"
     "CREATE TABLE links (
	pos NOT NULL,
	source NOT NULL,
	dest NOT NULL,
	type NOT NULL,
	properties,
	FOREIGN KEY (source) REFERENCES nodes (id) ON DELETE CASCADE
);"))

  ;; First 7 tables above give us theoretical compatibility with org-roam db.
  ;; Now play with perf settings.
  ;; https://www.sqlite.org/pragma.html
  ;; https://www.sqlite.org/inmemorydb.html

  (sqlite-execute db "CREATE INDEX refs_node_id  ON refs    (node_id);")
  (sqlite-execute db "CREATE INDEX tags_node_id  ON tags    (node_id);")
  (sqlite-execute db "CREATE INDEX alias_node_id ON aliases (node_id);")
  (sqlite-execute db "PRAGMA cache_size = -40000;") ;; 40,960,000 bytes

  ;; Full disclosure, I have no idea what I'm doing
  (sqlite-execute db "PRAGMA mmap_size = 40960000;")
  (sqlite-execute db "PRAGMA temp_store = memory;")
  (sqlite-execute db "PRAGMA synchronous = off;")
  db)

(defun indexed-roam--populate-usably-for-emacsql (db row-sets)
  (seq-let (files nodes aliases citations refs tags links) row-sets
    (with-sqlite-transaction db
      (when files
        (sqlite-execute
         db (concat
             "INSERT INTO files VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql files))))
      (when nodes
        (sqlite-execute
         db (concat
             "INSERT INTO nodes VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql nodes))))
      (when aliases
        (sqlite-execute
         db (concat
             "INSERT INTO aliases VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql aliases))))
      (when citations
        (sqlite-execute
         db (concat
             "INSERT INTO citations VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql citations))))
      (when refs
        (sqlite-execute
         db (concat
             "INSERT INTO refs VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql refs))))
      (when tags
        (sqlite-execute
         db (concat
             "INSERT INTO tags VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql tags))))
      (when links
        (sqlite-execute
         db (concat
             "INSERT INTO links VALUES "
             (indexed-roam--mk-singular-value-quoted-like-emacsql links)))))))

(defun indexed-roam--mk-singular-value-quoted-like-emacsql (rows)
  "Turn ROWS into literal \(not prepared) value for a SQL INSERT.
In each row, print atoms that are strings or lists, readably."
  (with-temp-buffer
    (let ((print-level nil)
          (print-length nil)
          (print-escape-newlines t)
          (print-escape-control-characters t)
          row beg)
      (while (setq row (pop rows))
        (insert "(")
        (cl-loop for value in row do
                 (cond ((null value)
                        (insert "NULL"))
                       ((numberp value)
                        (insert (number-to-string value)))
                       ((progn
                          (insert "'")
                          (setq beg (point))
                          (prin1 value (current-buffer))
                          (goto-char beg)
                          (while (search-forward "'" nil t)
                            (insert "'"))
                          (goto-char (point-max))
                          (insert "'"))))
                 (insert ", "))
        (unless (= 2 (point)) ;; In case above loop was a no-op
          (delete-char -2))
        (insert "), "))
      (unless (bobp) ; In case ROWS was empty
        (delete-char -2)))
    (buffer-string)))

(defun indexed-roam--mk-rows (&optional specific-files)
  "Return rows of data suitable for inserting into `indexed-roam' DB.

Specifically, return seven lists of rows, one for each SQL table
defined by `indexed-roam--configure'.

With SPECIFIC-FILES, only return data that involves those files."
  (let (file-rows
        node-rows
        alias-rows
        citation-rows
        ref-rows
        tag-rows
        link-rows
        prop-rows
        (print-length nil)
        (seen-files (make-hash-table :test 'equal)))
    (cl-loop
     for entry in (indexed-org-id-nodes)
     as file = (indexed-file-name entry)
     when (or (not specific-files) (member file specific-files))
     do
     (unless (gethash file seen-files)
       (puthash file t seen-files)
       (push (indexed-roam--mk-file-row file) file-rows))
     (cl-symbol-macrolet ((deadline   (indexed-deadline entry))
                          (id         (indexed-id entry))
                          (scheduled  (indexed-scheduled entry))
                          (properties (indexed-properties entry)))
       ;; See `org-roam-db-insert-aliases'
       (cl-loop for alias in (indexed-roam-aliases entry) do
                (push (list id alias) alias-rows))
       ;; See `org-roam-db-insert-tags'
       (cl-loop for tag in (indexed-tags entry) do
                (push (list id tag) tag-rows))
       ;; See `org-roam-db-insert-file-node' and `org-roam-db-insert-node-data'
       (push (list id
                   (indexed-file-name entry)
                   (indexed-heading-lvl entry)
                   (indexed-pos entry)
                   (indexed-todo-state entry)
                   (indexed-priority entry)
                   (indexed-scheduled entry)
                   (indexed-deadline entry)
                   (indexed-title entry)
                   (indexed-properties entry)
                   (indexed-olpath entry))
             node-rows)
       ;; See `org-roam-db-insert-refs'
       (cl-loop for ref in (indexed-roam-refs entry) do
                (let ((type (gethash ref indexed-roam--ref<>type)))
                  (push (list id
                              ref
                              (or type "cite"))
                        ref-rows)))
       (cl-loop for (prop . val) in properties
                do (push (list id prop val) prop-rows)))
     (dolist (link (append (indexed-id-links-to entry)
                           (indexed-roam-reflinks-to entry)))
       (let ((origin-node (gethash (indexed-origin link) indexed--id<>entry)))
         (if (not (indexed-pos link))
             (message "Null link pos in %s" link))
         (if (not origin-node)
             (message "Unknown ID: %s" (indexed-origin link))
           (if (indexed-type link)
               ;; See `org-roam-db-insert-link'
               (push (list (indexed-pos link)
                           (indexed-origin link)
                           (indexed-dest link)
                           (indexed-type link)
                           nil)
                     link-rows)
             ;; See `org-roam-db-insert-citation'
             (push (list (indexed-origin link)
                         (substring (indexed-dest link) 1)
                         (indexed-pos link)
                         nil)
                   citation-rows))))))
    (list file-rows
          node-rows
          alias-rows
          citation-rows
          ref-rows
          tag-rows
          link-rows
          prop-rows)))

;; Numeric times are can be mixed with Lisp times:
;;    (format-time-string "%F %T" (time-add (time-to-seconds) 100))
;;    (format-time-string "%F %T" (time-add (current-time) 100))
;; So, we skip the overhead of `prin1-to-string' and just store integer mtime.
(defun indexed-roam--mk-file-row (file)
  "Return info about FILE."
  (let ((data (indexed-file-data file)))
    (list file
          (indexed-file-title data)
          ""                        ; HACK: Hashing is slow, skip
          (indexed-file-mtime data) ; HACK: org-roam doesn't use atime anyway
          (indexed-file-mtime data))))


;;; Update-on-save

(defun indexed-roam--update-db (parse-results)
  "Update current DB about nodes and links involving FILES.
Suitable on `indexed-post-incremental-update-functions'."
  ;; NOTE: There's a likely performance bug in Emacs sqlite.c.
  ;;       I have a yuge file, which takes 0.01 seconds to delete on the
  ;;       sqlite3 command line... but 0.53 seconds with `sqlite-execute'.
  ;;
  ;;       Aside from tracking down the bug, could we workaround by getting rid
  ;;       of all the CASCADE rules and pre-determine what needs to be deleted?
  ;;       It's not The Way to use a RDBMS, but it's a simple enough puzzle.
  (let* ((db (indexed-roam))
         (files (mapcar #'indexed-file-name (nth 1 parse-results)))
         (rows (indexed-roam--mk-rows files)))
    (dolist (file files)
      (sqlite-execute db "DELETE FROM files WHERE file LIKE ?;" (list file)))
    (indexed-roam--populate-usably-for-emacsql db rows)))


;;; Dev tools

(defvar emacsql-type-map)
(defun indexed-roam--insert-schemata-atpt ()
  "Print `org-roam-db--table-schemata' as raw SQL at point."
  (interactive)
  (require 'org-roam)
  (require 'emacsql)
  (when (and (boundp 'org-roam-db--table-schemata)
             (fboundp 'emacsql-format)
             (fboundp 'emacsql-prepare))
    (cl-loop
     with emacsql-type-map = '((integer "INTEGER")
                               (float "REAL")
                               (object "TEXT")
                               (nil nil))
     with exp = (let ((exp* (emacsql-prepare [:create-table $i1 $S2])))
                  (cons (thread-last (car exp*)
                                     (string-replace "("  "(\n\t")
                                     (string-replace ")"  "\n)"))
                        (cdr exp*)))
     for (table schema) in org-roam-db--table-schemata
     do (insert " \n\""
                (string-replace ", " ",\n\t"
                                (emacsql-format exp table schema))
                ";\""))))


;;; Bonus utilities

;; If saving buffers is slow with org-roam.  Stop updating org-roam.db on save,
;; and use this shim to let your *org-roam* buffer be up to date anyway.
;; Setup:

;; (setq org-roam-db-update-on-save nil) ;; if saving is slow
;; (indexed-updater-mode)
;; (indexed-roam-mode)
;; (advice-add 'org-roam-backlinks-get :override #'indexed-roam-mk-backlinks)
;; (advice-add 'org-roam-reflinks-get  :override #'indexed-roam-mk-reflinks)

(declare-function org-roam-node-create "org-roam-node")
(declare-function org-roam-node-id "org-roam-node")
(declare-function org-roam-reflink-create "org-roam-mode")
(declare-function org-roam-backlink-create "org-roam-mode")

(defun indexed-roam-mk-node (entry)
  "Make an org-roam-node object, from indexed object ENTRY."
  (require 'org-roam-node)
  (unless (indexed-id entry)
    (error "indexed-roam-mk-node: An ID-less entry cannot make an org-roam-node: %s"
           entry))
  (org-roam-node-create
   :file (indexed-file-name entry)
   :id (indexed-id entry)
   :scheduled (when-let* ((scheduled (indexed-scheduled entry)))
                (concat (substring scheduled 1 11) "T12:00:00"))
   :deadline (when-let* ((deadline (indexed-deadline entry)))
               (concat (substring deadline 1 11) "T12:00:00"))
   :level (indexed-heading-lvl entry)
   :title (indexed-title entry)
   :file-title (indexed-file-title entry)
   :tags (indexed-tags entry)
   :aliases (indexed-roam-aliases entry)
   :todo (indexed-todo entry)
   :refs (indexed-roam-refs entry)
   :point (indexed-pos entry)
   :priority (indexed-priority entry)
   :properties (indexed-properties entry)
   :olp (indexed-olpath entry)))

(defun indexed-roam-mk-backlinks (target-roam-node &rest _)
  "Make `org-roam-backlink' objects pointing to TARGET-ROAM-NODE.

Can be used in two ways:
- As override-advice for `org-roam-backlinks-get'.
- Directly, if TARGET-ROAM-NODE is an output of `indexed-roam-mk-node'."
  (require 'org-roam-mode)
  (require 'org-roam-node)
  (let* ((target-id (org-roam-node-id target-roam-node))
         (links (gethash target-id indexed--dest<>links)))
    (cl-loop
     for link in links
     as src-id = (indexed-origin link)
     as src-entry = (gethash src-id indexed--id<>entry)
     when src-entry
     collect (org-roam-backlink-create
              :target-node target-roam-node
              :source-node (indexed-roam-mk-node src-entry)
              :point (indexed-pos link)))))

;; REVIEW:  Are our refs exactly the same as org-roam's refs?
(defun indexed-roam-mk-reflinks (target-roam-node &rest _)
  "Make `org-roam-reflink' objects pointing to TARGET-ROAM-NODE.

Can be used in two ways:
- As override-advice for `org-roam-reflinks-get'.
- Directly, if TARGET-ROAM-NODE is an output of `indexed-roam-mk-node'."
  (require 'org-roam-mode)
  (require 'org-roam-node)
  (let* ((target-id (org-roam-node-id target-roam-node))
         (entry (gethash target-id indexed--id<>entry)))
    (when entry
      (cl-loop
       for ref in (indexed-roam-refs entry)
       append (cl-loop
               for link in (gethash ref indexed--dest<>links)
               as src-id = (indexed-origin link)
               as src-entry = (gethash src-id indexed--id<>entry)
               when src-entry
               collect (org-roam-reflink-create
                        :ref (indexed-dest link)
                        :source-node (indexed-roam-mk-node src-entry)
                        :point (indexed-pos link)))))))

(provide 'indexed-roam)

;;; indexed-roam.el ends here
