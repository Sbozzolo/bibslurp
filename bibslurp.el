;;; bibslurp.el --- retrieve BibTeX entries from NASA ADS

;; Copyright (C) 2019 Gabriele Bozzola
;; Copyright (C) 2013-2018 Mike McCourt
;;
;; Authors: Mike McCourt <mkmcc@astro.berkeley.edu>
;;          Gabriele Bozzola <gabrielebozzola@email.arizona.edu>
;; URL: https://github.com/mkmcc/bibslurp
;; Version: 0.0.3
;; Keywords: bibliography, nasa ads
;; Package-Requires: ((s "1.6.0") (dash "1.5.0") (request "0.3.0"))

;; This file is not part of GNU Emacs.

;; bibslurp is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.
;;
;; bibslurp is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with bibslurp.  If not, see http://www.gnu.org/licenses.

;;; Commentary:

;; Provides a function `bibslurp-query-ads', which reads a search
;; string from the minibuffer, sends the query to NASA ADS
;; (http://adswww.harvard.edu/), and displays the results in a new
;; buffer called "ADS Search Results".

;; The "ADS Search Results" buffer opens in `bibslurp-mode', which
;; provides a few handy functions.  Typing the number preceding an
;; abstract and hitting RET calls `bibslurp-slurp-bibtex', which
;; fetches the bibtex entry corresponding to the abstract and saves it
;; to the kill ring.  Typing 'a' instead pulls up the abstract page.
;; At anytime, you can hit 'q' to quit bibslurp-mode and restore the
;; previous window configuration.

;;; Example usage:

;; add an entry to a bibtex buffer:
;;   M-x bibslurp-query-ads RET ^Quataert 2008 RET
;; Move to the abstract you want to cite with n and p keys, or search
;; in the buffer with s or r, and then press
;;   RET
;;   q
;;   C-y

;; For more examples and information see the project page at
;; http://astro.berkeley.edu/~mkmcc/software/bibslurp.html

;;; Advanced search
;; You can turn to the ADS advanced search interface, akin to
;; http://adsabs.harvard.edu/abstract_service.html, either by pressing
;; C-c C-c after having issued `bibslurp-query-ads', or directly with
;;   M-x `bibslurp-query-ads-advanced-search' RET
;; Here you can fill the wanted search fields (authors, publication
;; date, objects, title, abstract) and specify combination logics, and
;; then send the query either with C-c C-c or by pressing the button
;; "Send Query".  Use TAB to move through fields, and q outside an
;; input field to quit the search interface.

;;; Other features
;; In the ADS search result buffer you can also visit some useful
;; pages related to each entry:
;;  - on-line data at other data centers, with d
;;  - on-line version of the selected article, with e
;;  - on-line articles in PDF or Postscript, with f
;;  - lists of objects for the selected abstract in the NED database,
;;    with N
;;  - lists of objects for the selected abstract in the SIMBAD
;;    database, with S
;;  - on-line pre-print version of the article in the arXiv database,
;;    with x
;; For each of these commands, BibSlurp will use by default the
;; abstract point is currenly on, but you can specify a different
;; abstract by prefixing the command with a number.  For example,
;;   7 x
;; will fire up your browser to the arXiv version of the seventh
;; abstract in the list.

;;; Installation:

;; Use package.el. You'll need to add MELPA to your archives:

;; (require 'package)
;; (add-to-list 'package-archives
;;              '("melpa" . "https://melpa.org/packages/") t)

;; Alternatively, you can just save this file and do the standard
;; (add-to-list 'load-path "/path/to/bibslurp.el")
;; (require 'bibslurp)
;;
;; A ADS API token is needed. The instructions to get one can be
;; found at the webpage:
;; https://github.com/adsabs/adsabs-dev-api#access
;; Once you have a token, set the variable ads-auth-token to your
;; token.

;;; Code:
(require 's)
(require 'request)
(require 'dash)
(require 'widget)
(eval-when-compile
  (require 'wid-edit))

(defgroup bibslurp nil
  "Retrieve BibTeX entries from NASA ADS."
  :prefix "bibslurp-"
  :group 'convenience
  :tag "bibslurp"
  :link '(url-link :tag "Home Page"
		   "https://mkmcc.github.io/software/bibslurp.html"))

(defcustom ads-auth-token nil
  "ADS API token. To generate an access token visit the page:
https://github.com/adsabs/adsabs-dev-api#access. Then, save it to
this variable with (setq ads-auth-token TOKEN)."
  :type 'string
  :group 'bibslurp)

(defcustom bibslurp-bibtex-label-format 'author-year
  "Format of the label of the BibTeX entry provided.
It can be either
 * 'author-year
 * 'bibcode"
  :group 'bibslurp
  :type '(choice (const :tag "AuthorYear" author-year)
		 (const :tag "Bibcode"    bibcode)))

;; define font-lock faces
(defface bibslurp-number-face
  '((t (:inherit 'font-lock-string-face)))
  "Face for entry number.")

(defface bibslurp-name-face
  '((t (:inherit 'italic)))
  "Face for entry name.")

(defface bibslurp-score-face
  '((t (:inherit 'font-lock-comment-face)))
  "Face for entry score.")

(defface bibslurp-date-face
  '((t (:inherit 'font-lock-variable-name-face)))
  "Face for entry date.")

(defface bibslurp-author-face
  '((t (:inherit 'font-lock-builtin-face)))
  "Face for entry authors")

(defface bibslurp-title-face
  '((t (:inherit 'font-lock-string-face)))
  "Face for entry title.")

;; key bindings
(defvar bibslurp-mode-map
  (let ((map (make-keymap)))
    (suppress-keymap map)
    (define-key map (kbd "RET") 'bibslurp-slurp-bibtex)
    (define-key map (kbd "z")   'bibslurp-slurp-bibtex)
    (define-key map "a" 'bibslurp-show-abstract)
    ;; Navigation
    (define-key map (kbd "SPC")   'scroll-up)
    (define-key map (kbd "S-SPC") 'scroll-down)
    (define-key map ">" 'end-of-buffer)
    (define-key map "<" 'beginning-of-buffer)
    (define-key map "n" 'bibslurp-next-entry)
    (define-key map "p" 'bibslurp-previous-entry)
    ;; Search
    (define-key map "r" 'isearch-backward)
    (define-key map "s" 'isearch-forward)
    ;; Quit
    (define-key map "q" 'bibslurp-quit)
    ;; Retrieve useful stuff
    (define-key map "e" 'bibslurp-visit-journal)
    (define-key map "f" 'bibslurp-visit-article)
    (define-key map "x" 'bibslurp-visit-arxiv)
    (define-key map "d" 'bibslurp-visit-data)
    (define-key map "S" 'bibslurp-visit-ned)
    (define-key map "N" 'bibslurp-visit-ned)
    map)
  "Keymap for bibslurp mode.")

(define-derived-mode bibslurp-mode fundamental-mode "BibSlurp"
  "Major mode for perusing ADS search results and slurping bibtex
entries to the kill-ring.  This is pretty specific, so you should
only enter the mode via `bibslurp-query-ads'.

\\<bibslurp-mode-map>"
  (use-local-map bibslurp-mode-map))

(defun bibslurp-quit ()
  "Close the bibslurp buffer and restore the previous window
configuration."
  (interactive)
  (kill-buffer)
  (when (get-register :bibslurp-window)
    (jump-to-register :bibslurp-window)))

;; Functions to interface with ADS APIs
(defun bibslurp/find-number-of-results (search-string)
  "Make the API request and find how many results are expected."
  (cdr (assoc 'numFound
          (assoc 'response
                 (request-response-data (request
		                         "https://api.adsabs.harvard.edu/v1/search/query"
		                         :headers
		                         `(("Authorization" . ,(concat "Bearer " ads-auth-token)))
		                         :params
		                         `(("q" . ,search-string))
		                         :type "GET"
                                        ; Why does this sync have to be here?
                                         :sync t
		                         :parser 'json-read))))))


(defun bibslurp/make-request (search-string)
  "Make the API request using the token and retrieving
 * 1: score
 * 2: bibcode
 * 3: date
 * 4: authors
 * 5: title
   The output is a nested list with the request data already parsed."
  (request-response-data (request
		  "https://api.adsabs.harvard.edu/v1/search/query"
		  :headers
		  `(("Authorization" . ,(concat "Bearer " ads-auth-token)))
		  :params
		  `(("q" . ,search-string) ("fl" . "bibcode,year,author,title,score")
                    ("rows" . 2000)
                    )
		  :type "GET"
                  ; Why does this sync have to be here?
                  :sync t
		  :parser 'json-read)))

(defun bibslurp/make-request-bibtex (bibcode)
  "Make the API request using the token to obtain the bibtex file."
  (request-response-data (request
		  "https://api.adsabs.harvard.edu/v1/export/bibtex"
		  :headers
		  `(("Authorization" . ,(concat "Bearer " ads-auth-token)))
		  :data
		  `(("bibcode" . ,bibcode))
		  :type "POST"
                  ; Why does this sync have to be here?
                  :sync t
		  :parser 'json-read)))

(defun bibslurp/make-request-additional-info (bibcode)
  "Make the API request using the token to obtain additional information.
At the moment, title,abstract, journal, date and authors."
  (request-response-data (request
		  "https://api.adsabs.harvard.edu/v1/search/query"
		  :headers
		  `(("Authorization" . ,(concat "Bearer " ads-auth-token)))
		  :params
		  `(("q" . ,bibcode)
                    ("fl" . "title,abstract,pub,author,year,citation_count")
                    )
		  :type "GET"
                  ; Why does this sync have to be here?
                  :sync t
		  :parser 'json-read)))


(defun bibslurp/request-bibtex (bibcode)
  "Return the actual bibtex file corresponding the bibcode by making a
request and parsing the output."
  ;; Extract the file from the query response.
  (cdr (assoc 'export (bibslurp/make-request-bibtex bibcode)))
  )

(defun bibslurp/extract-data-from-request (request-data)
  "Return the actual data of interest among all the output from
   the query. This is done by extracting the 'docs field.
   The return value is a vector with all the available results."
  (cdr (assoc 'docs (assoc 'response request-data)))
  )

(defun bibslurp/requested-data (search-string)
  "Make the query and return the data."
  (bibslurp/extract-data-from-request (bibslurp/make-request search-string))
  )

(defun bibslurp/request-additional-info (bibcode)
  "Make the query and return the data in a associative list."
  ;; The output is in form of a vector, we just need the first entry
  (aref (bibslurp/extract-data-from-request
         (bibslurp/make-request-additional-info bibcode)) 0))

(defun bibslurp/clean-entry-from-request (entry)
  "Return the same list as returned by the old
   bibslurp/clean-entry but with data obtained via API, except
   for the number which is added with bibslurp/prepare-entry-list."
  (let ((score     (number-to-string (cdr (assoc 'score entry))))
        (date      (cdr (assoc 'year entry)))
        ; Transform vector into string
        (authors   (mapconcat 'identity (cdr (assoc 'author entry)) "; "))
        (abs-name  (cdr (assoc 'bibcode entry)))
        (title     (aref (cdr (assoc 'title entry)) 0))
        )
        (list score abs-name date authors title))
  )

(defun bibslurp/prepare-entry-list (requested-data)
  "Prepend the number of the result to the requested data."
  (seq-map-indexed
   (lambda
     (entry idx)
     (cons (number-to-string idx) (bibslurp/clean-entry-from-request entry)))
   requested-data)
  )

;; functions to parse and display the search results page.
(defvar bibslurp-query-history nil
  "History for `bibslurp-query-ads'.")

(defvar bibslurp-entry-list nil
  "List of entries for the current search.

For each entry, the elements are:
 * 0: number of the entry, starting from 1
 * 1: score
 * 2: bibcode
 * 3: date
 * 4: authors
 * 5: title
 * 6: URL of the abstract
All elements are string.")

(defun bibslurp/search-results (search-url &optional search-string)
  "Create the buffer for the results of a search.

Displays results in a new buffer called \"ADS Search Results\"
and enters `bibslurp-mode'.  You can retrieve a bibtex entry by
typing the number in front of the abstract link and hitting
enter.  Hit 'a' instead to pull up the abstract.  You can exit
the mode at any time by hitting 'q'."
  (let ((buf (get-buffer-create "ADS Search Results"))
        (inhibit-read-only t))
    (with-temp-buffer
      (url-insert-file-contents search-url)
      (setq bibslurp-entry-list
	    (-map 'bibslurp/clean-entry (bibslurp/read-table)))
      )
    (with-current-buffer buf
      (erase-buffer)
      (insert "ADS Search Results for "
	      ;; `search-string' is nil when we use advanced search.
              (if search-string
		  (concat "\"" (propertize search-string
					   'face 'font-lock-string-face) "\"")
		"advanced search")
              "\n\n")
      (insert
       (propertize
        (concat
         "Scroll with SPC and SHIFT-SPC, or search using 's' and 'r'."
         "\n\n"
         "* To slurp a bibtex entry, type the number of the abstract and hit RET."
         "\n\n"
         "* To view an abstract, type the number of the abstract and hit 'a'."
         "\n\n"
         "* To quit and restore the previous window configuration, hit 'q'."
         "\n\n\n\n") 'face 'font-lock-comment-face))
      (save-excursion
        (insert
         (mapconcat 'identity
		    (--map (apply 'bibslurp/print-entry it)
			   bibslurp-entry-list) ""))
	;; Shave off the last newlines
	(delete-char -4))
      (bibslurp-mode))
    (switch-to-buffer buf)
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)
    (delete-other-windows)))

(defun bibslurp/search-results-with-request (requested-data &optional search-string)
  "Create the buffer for the results of a search.

Displays results in a new buffer called \"ADS Search Results\"
and enters `bibslurp-mode'.  You can retrieve a bibtex entry by
typing the number in front of the abstract link and hitting
enter.  Hit 'a' instead to pull up the abstract.  You can exit
the mode at any time by hitting 'q'."
  (let ((buf (get-buffer-create "ADS Search Results"))
        (inhibit-read-only t))
      (setq bibslurp-entry-list
	    (bibslurp/prepare-entry-list requested-data))
    (with-current-buffer buf
      (erase-buffer)
      (insert "ADS Search Results for "
	      ;; `search-string' is nil when we use advanced search.
              (if search-string
		  (concat "\"" (propertize search-string
					   'face 'font-lock-string-face) "\"")
		"advanced search")
              "\n\n")
      (insert
       (propertize
        (concat
         "Scroll with SPC and SHIFT-SPC, or search using 's' and 'r'."
         "\n\n"
         "* To slurp a bibtex entry, type the number of the abstract and hit RET."
         "\n\n"
         "* To view an abstract, type the number of the abstract and hit 'a'."
         "\n\n"
         "* To quit and restore the previous window configuration, hit 'q'."
         "\n\n\n\n") 'face 'font-lock-comment-face))
      (save-excursion
        (insert
         (mapconcat 'identity
		    (--map (apply 'bibslurp/print-entry it)
			   bibslurp-entry-list) ""))
	;; Shave off the last newlines
	(delete-char -4))
      (bibslurp-mode))
    (switch-to-buffer buf)
    (setq buffer-read-only t)
    (set-buffer-modified-p nil)
    (delete-other-windows)))


;;;###autoload
(defun bibslurp-query-ads (&optional search-string)
  "Ask for a search string and sends the query to NASA ADS.

Press \"C-c C-c\" to turn to the advanced search interface."
  (interactive)
  (if (not ads-auth-token)
      (error "API key not set! Set the variable ads-auth-token")
    (let ((map (make-sparse-keymap)))
      (set-keymap-parent map minibuffer-local-map)
      ;; Bind C-c C-c to abort reading from minibuffer.  This throws a `quit'
      ;; signal that we can catch later.
      (define-key map "\C-c\C-c"
        (lambda ()
	  (interactive)
	  (abort-recursive-edit)))
      (condition-case nil
	  (progn
	    ;; Read the search string from minibuffer, if not provided as
	    ;; argument.
	    (unless search-string
	      (setq search-string
		    (read-from-minibuffer "Search string: " nil map nil
					  'bibslurp-query-history)))
	    ;; Show search results for the given search string.
	    (window-configuration-to-register :bibslurp-window)
            (bibslurp/search-results-with-request (bibslurp/requested-data search-string)
	        		                  search-string)
            )
        ;; We've received a `quit' signal.  If it has been thrown by C-c C-c,
        ;; start the ADS advanced search, otherwise emit the standard error.
        ;; XXX: actually `last-input-event' holds only the very last event (C-c,
        ;; in this case), we must hope the user didn't bind other keys ending in
        ;; C-c to a `quit' signal, but this isn't the case in the standard
        ;; configuration.
        (quit (if (equal last-input-event ?\C-c)
		  (bibslurp-query-ads-advanced-search)
	        (error "Quit")))))))

(defun bibslurp/read-table ()
  "Parse the HTML from a search results page.

TODO: describe in more detail.  also rethink this."
  (goto-char (point-min))
  ;; search results are printed in a <table> element.  annoyingly, one
  ;; result actually spans *two* adjacent table rows, so we keep a
  ;; temp variable to store and combine them.
  (re-search-forward "<table>")
  (let ((rows '())
        (temp '()))
    ;; find the next <tr>...</tr> block
    (while (re-search-forward "<tr>" nil t)
      (let ((end (save-excursion
                   (re-search-forward "</tr>")
                   (point)))
            (data '()))
        ;; populate data with the <td>...</td> entries
        (while (re-search-forward "<td[^>]*>\\(.*?\\)</td>" end t)
          (add-to-list 'data (match-string-no-properties 1) t))
        ;; search results start with a number.  if this is a new
        ;; search result, store it in the temp variable.  otherwise,
        ;; if temp is non-nil, this is the continuation of a search
        ;; result.  append them and add to the rows list.
        (cond
         ((and (car data) (s-numeric? (car data)))
          (setq temp data))
         (temp
          (add-to-list 'rows (append temp data) t)
          (setq temp '())))))
    rows))

(defun bibslurp/clean-entry (entry)
  "Process the data returned by `bibslurp/read-table' into
something human readable.

Note that this function depends on the *order* of <td> elements
not changing in the ADS pages.  I pretty much have to hope that
that's the case..."
  (let ((num       (nth 0 entry))
        (link-data (nth 1 entry))
        (score     (nth 3 entry))
        (date      (nth 4 entry))
        (authors   (nth 7 entry))
        (title     (nth 9 entry)))
    (when (string-match "<a href=\"\\([^\"]+?\\)\">\\([^<]+\\)</a>" link-data)
      (let ((abs-url (match-string-no-properties 1 link-data))
            (abs-name (match-string-no-properties 2 link-data)))
	;; Decode HTML entities.  XXX: the only entity I know it is used in
	;; bibcodes is "&amp;".  Should we need to decode much more entitites
	;; there is `xml-parse-string', but we would require xml library then.
	;; XXX: probably would be even better not to get the bibcode from HTML
	;; at all, if possible.
	(setq abs-name (replace-regexp-in-string "&amp;" "&" abs-name))
        (list num score abs-name date authors title abs-url)))))

(defun bibslurp/print-entry (num score abs-name date authors title)
  "Format a single search result for printing.

TODO: this is really messy code.  cleanup."
  (let* ((fmt-num (concat
                   (make-string (- 3 (length num)) ? )
                   (format "[%s].  %s"
                           (propertize num 'face 'bibslurp-number-face)
                           (propertize abs-name 'face 'bibslurp-name-face))))
         (fmt-score (propertize (format "(%s)" score) 'face 'bibslurp-score-face))
         (pad (make-string (- 80 (length fmt-num) (length fmt-score)) ? ))
         (meta (concat fmt-num pad fmt-score)))
    ;; Attach information like bibcode, authors and date.
    ;; This is used later.
    (propertize
     (concat meta "\n"
	     (s-truncate 80
			 (concat (make-string 8 ? )
				 (propertize date 'face 'bibslurp-date-face) " "
				 (propertize authors 'face 'bibslurp-author-face)))
	     "\n\n"
	     (when title (s-word-wrap 80 title))
	     "\n\n\n\n") 'number num 'bibcode abs-name 'authors authors 'date date)))

(defun bibslurp/bibcode-to-bibtex (bibcode &optional new-label)
  "Take the bibcode for an ADS bibtex entry and return the entry as a
string.  The format of the label is controlled by
`bibslurp-bibtex-label-format'."
  (if (not (equal bibslurp-bibtex-label-format 'author-year))
      (bibslurp/request-bibtex bibcode) ; Return bibtex with bibcode
    (let ((bibtex (bibslurp/request-bibtex bibcode)))
       (when (not (string-equal new-label ""))
         (progn
           (string-match "@\\sw+{\\([^,]+\\)," bibtex)
           (replace-match new-label t t bibtex 1))))))

(defun bibslurp-slurp-bibtex ()
  "Automatically find the bibtex entry for an abstract in the
NASA ADS database. It works on the entry at the point."
  (interactive)
  (let ((bibcode (get-text-property (point) 'bibcode))
        (authors (get-text-property (point) 'authors))
        (date (get-text-property (point) 'date)))
    (kill-new (bibslurp/bibcode-to-bibtex
               bibcode
               (bibslurp/suggest-label authors date)
               ))
    (message "Saved bibtex entry to kill-ring.")
    )
  )

(defun bibslurp/suggest-label (authors date)
  "Parse an abstract page and suggest a bibtex label.  Returns an
empty string if no suggestion is found.

TODO: Improve support for non ASCII characters.
"
  ;; Take first entry of author list and year in date
    (concat (car (split-string authors ",")) (s-left 4 date)))

;;; functions to display abstracts

(defun bibslurp/format-abs (bibcode)
  "Query for additional information related to the chosen bibcode
and display in a new buffer. Wrap text is it is longer than fill-column."
  (let* ((additional-info (bibslurp/request-additional-info bibcode))
         (title (aref (cdr (assoc 'title additional-info)) 0))
         (authors   (mapconcat 'identity (cdr (assoc 'author additional-info)) "; "))
         (date (cdr (assoc 'year additional-info)))
         (abs (cdr (assoc 'abstract additional-info)))
         (journal (cdr (assoc 'pub additional-info)))
         (citations (number-to-string (cdr (assoc 'citation_count additional-info))))
         (inhibit-read-only t))
      (let ((buf (get-buffer-create "ADS Abstract")))
        (with-current-buffer buf
          (erase-buffer)
          (insert (propertize (s-word-wrap fill-column title) 'face 'bibslurp-title-face) "\n")
          (insert (propertize (s-word-wrap fill-column authors) 'face 'bibslurp-author-face) "\n")
          (insert journal ", " date "\n")
          (insert "Citations: " citations "\n")
          (insert "\n\n")
          (insert (s-word-wrap fill-column abs))
          (view-mode)
          (local-set-key (kbd "q") 'kill-buffer))
        (switch-to-buffer buf))))

(defun bibslurp-show-abstract ()
  "Display the abstract page for a specified link number."
  (interactive)
  (bibslurp/format-abs (get-text-property (point) 'bibcode))
  )

;;; Navigation

(defun bibslurp-next-entry ()
  "Move to the next entry."
  (interactive)
  (let ((pos (next-single-property-change (point) 'number)))
    (if (integerp pos)
	(goto-char pos))))

(defun bibslurp-previous-entry ()
  "Move to the previous entry."
  (interactive)
  (let ((pos (previous-single-property-change (point) 'number)))
    (if (integerp pos)
	(goto-char pos))))

;;; Retrieve useful stuff

(defun bibslurp/visit-something (type &optional number)
  "Visit link specified by TYPE.
TYPE can be
 * 'journal
 * 'article
 * 'arvix
 * 'data
 * 'simbad
 * 'ned
NUMBER is the entry number in `bibslurp-entry-list'.  If it is
not provided, use the entry number at point, otherwise prompt the
user for inserting it. "
  (setq number
	(or number
	    current-prefix-arg
	    (get-text-property (point) 'number)
	    (read-string "Link number: ")))
  (if (numberp number)
      (setq number (number-to-string number)))
  (browse-url
   (format
    "http://adsabs.harvard.edu/cgi-bin/nph-data_query?bibcode=%s&db_key=AST&link_type=%s"
    (nth 2 (assoc-string number bibslurp-entry-list))
    (cond ((equal type 'journal) "EJOURNAL")
	  ((equal type 'article) "ARTICLE")
	  ((equal type 'arxiv)   "PREPRINT")
	  ((equal type 'data)    "DATA")
	  ((equal type 'simbad)  "SIMBAD")
	  ((equal type 'ned)     "NED")
	  (t                     "")))))

(defun bibslurp-visit-journal (&optional number)
  "Visit journal page for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'journal number))

(defun bibslurp-visit-article (&optional number)
  "Download article for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'article number))

(defun bibslurp-visit-arxiv (&optional number)
  "Visit arXiv for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'arxiv number))

(defun bibslurp-visit-data (&optional number)
  "Visit data for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'data number))

(defun bibslurp-visit-simbad (&optional number)
  "Visit SIMBAD for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'simbad number))

(defun bibslurp-visit-ned (&optional number)
  "Visit NED for entry NUMBER in `bibslurp-entry-list'."
  (interactive)
  (bibslurp/visit-something 'ned number))

;;; Advanced search

(defvar-local bibslurp/advanced-search-ast nil)
(defvar-local bibslurp/advanced-search-phy nil)
(defvar-local bibslurp/advanced-search-pre nil)
(defvar-local bibslurp/advanced-search-authors nil)
(defvar-local bibslurp/advanced-search-author-logic nil)
(defvar-local bibslurp/advanced-search-start-mon nil)
(defvar-local bibslurp/advanced-search-start-year nil)
(defvar-local bibslurp/advanced-search-end-mon nil)
(defvar-local bibslurp/advanced-search-end-year nil)
(defvar-local bibslurp/advanced-search-object-logic nil)
(defvar-local bibslurp/advanced-search-object nil)
(defvar-local bibslurp/advanced-search-sim nil)
(defvar-local bibslurp/advanced-search-ned nil)
(defvar-local bibslurp/advanced-search-adsobj nil)
(defvar-local bibslurp/advanced-search-title nil)
(defvar-local bibslurp/advanced-search-title-logic nil)
(defvar-local bibslurp/advanced-search-abstract nil)
(defvar-local bibslurp/advanced-search-abstract-logic nil)

(defun bibslurp/advanced-search-build-url
    (ast phy pre authors author-logic start-mon start-year end-mon end-year
	 object object-logic sim ned adsobj title title-logic abstract
	 abstract-logic &rest _ignore)
  "Return the ADS search url for the advanced search."
  (let ((base-url "http://adsabs.harvard.edu/cgi-bin/nph-abs_connect?&qform=AST&arxiv_sel=astro-ph&arxiv_sel=cond-mat&arxiv_sel=cs&arxiv_sel=gr-qc&arxiv_sel=hep-ex&arxiv_sel=hep-lat&arxiv_sel=hep-ph&arxiv_sel=hep-th&arxiv_sel=math&arxiv_sel=math-ph&arxiv_sel=nlin&arxiv_sel=nucl-ex&arxiv_sel=nucl-th&arxiv_sel=physics&arxiv_sel=quant-ph&arxiv_sel=q-bio")
	(ast-url (if ast "&db_key=AST"))
	(phy-url (if phy "&db_key=PHY"))
	(pre-url (if pre "&db_key=PRE"))
	(sim-url    (if sim    "&sim_query=YES"    "&sim_query=NO"))
	(ned-url    (if ned    "&ned_query=YES"    "&ned_query=NO"))
	(adsobj-url (if adsobj "&adsobj_query=YES" "&adsobj_query=NO"))
	(aut-logic-url (concat "&aut_logic=" author-logic))
	(obj-logic-url (concat "&obj_logic=" object-logic))
	(authors-url
	 (concat "&author=" (replace-regexp-in-string " " "+" authors)))
	(object-url
	 (concat "&object=" (replace-regexp-in-string " " "+" object)))
	(start-mon-url  (concat "&start_mon=" start-mon))
	(start-year-url (concat "&start_year=" start-year))
	(end-mon-url  (concat "&end_mon=" end-mon))
	(end-year-url (concat "&end_year=" end-year))
	(ttl-logic-url (concat "&ttl_logic=" title-logic))
	(title-url
	 (concat "&title=" (replace-regexp-in-string " " "+" title)))
	(txt-logic-url (concat "&txt_logic=" abstract-logic))
	(text-url
	 (concat "&text=" (replace-regexp-in-string " " "+" abstract)))
	(end-url "&nr_to_return=200&start_nr=1&jou_pick=ALL&ref_stems=&data_and=ALL&group_and=ALL&start_entry_day=&start_entry_mon=&start_entry_year=&end_entry_day=&end_entry_mon=&end_entry_year=&min_score=&sort=SCORE&data_type=SHORT&aut_syn=YES&ttl_syn=YES&txt_syn=YES&aut_wt=1.0&obj_wt=1.0&ttl_wt=0.3&txt_wt=3.0&aut_wgt=YES&obj_wgt=YES&ttl_wgt=YES&txt_wgt=YES&ttl_sco=YES&txt_sco=YES&version=1"))
    (concat base-url ast-url phy-url pre-url sim-url ned-url adsobj-url
	    aut-logic-url obj-logic-url authors-url object-url start-mon-url
	    start-year-url end-mon-url end-year-url ttl-logic-url title-url
	    txt-logic-url text-url end-url)))

(defun bibslurp/advanced-search-send-query (&rest _ignore)
  "Send the query for the advanced search."
  (interactive)
  (bibslurp/search-results
   (bibslurp/advanced-search-build-url
    (widget-value bibslurp/advanced-search-ast)
    (widget-value bibslurp/advanced-search-phy)
    (widget-value bibslurp/advanced-search-pre)
    (widget-value bibslurp/advanced-search-authors)
    (widget-value bibslurp/advanced-search-author-logic)
    (widget-value bibslurp/advanced-search-start-mon)
    (widget-value bibslurp/advanced-search-start-year)
    (widget-value bibslurp/advanced-search-end-mon)
    (widget-value bibslurp/advanced-search-end-year)
    (widget-value bibslurp/advanced-search-object)
    (widget-value bibslurp/advanced-search-object-logic)
    (widget-value bibslurp/advanced-search-sim)
    (widget-value bibslurp/advanced-search-ned)
    (widget-value bibslurp/advanced-search-adsobj)
    (widget-value bibslurp/advanced-search-title)
    (widget-value bibslurp/advanced-search-title-logic)
    (widget-value bibslurp/advanced-search-abstract)
    (widget-value bibslurp/advanced-search-abstract-logic)))
  (kill-buffer "*ADS advanced search*"))


;;;###autoload
(defun bibslurp-query-ads-advanced-search ()
  "Query ADS using advanced search."
  (interactive)
  (window-configuration-to-register :bibslurp-window)
  (switch-to-buffer "*ADS advanced search*")
  (kill-all-local-variables)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays)

  ;; Welcome!
  (widget-insert
   (propertize "SAO/NASA ADS Custom query\n\n" 'font-lock-face '(:weight bold)))
  (widget-insert
   "Press C-c C-c to send the query, TAB to move to another field,
q (outside input fields) to exit.\n\n\n")

  ;; Prepare keymaps
  (let ((field-keymap (make-sparse-keymap))
	(keymap (make-sparse-keymap)))
    (set-keymap-parent field-keymap widget-field-keymap)
    (define-key field-keymap "\C-c\C-c"
      'bibslurp/advanced-search-send-query)

    (set-keymap-parent keymap widget-keymap)
    (define-key keymap "\C-c\C-c" 'bibslurp/advanced-search-send-query)
    (define-key keymap "q"        'bibslurp-quit)

    ;; Databases
    (widget-insert "Databases to query: ")
    (setq bibslurp/advanced-search-ast (widget-create 'checkbox t))
    (widget-insert " Astronomy ")
    (setq bibslurp/advanced-search-phy (widget-create 'checkbox nil))
    (widget-insert " Physics ")
    (setq bibslurp/advanced-search-pre (widget-create 'checkbox t))
    (widget-insert " arXiv e-prints\n\n")

    ;; Authors
    (setq bibslurp/advanced-search-authors
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'newline
			 :help-echo "C-c C-c: send the query; \
RET: insert a newline"
			 :format
			 (concat (propertize "Authors"
					     'font-lock-face '(:weight bold))
				 ": (Last, First M, one per line) %v")))
    ;; Authors logic
    (widget-insert "\nCombine authors with logic\n")
    (setq bibslurp/advanced-search-author-logic
	  (widget-create 'radio-button-choice
			 :value "OR"
			 '(item "OR") '(item "AND")
			 '(item :tag "simple logic" "SIMPLE")))

    ;; Publication date
    (widget-insert "\n\n")
    (widget-insert (propertize "Publication date"
			       'font-lock-face '(:weight bold)))
    (widget-insert ":\nbetween ")
    (setq bibslurp/advanced-search-start-mon
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'bibslurp/advanced-search-send-query
			 :help-echo "C-c C-c, RET: send the query"
			 :format "(MM) %v"))
    (setq bibslurp/advanced-search-start-year
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'bibslurp/advanced-search-send-query
			 :help-echo "C-c C-c, RET: send the query"
			 :format " (YYYY) %v"))
    (widget-insert "\n    and ")
    (setq bibslurp/advanced-search-end-mon
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'bibslurp/advanced-search-send-query
			 :help-echo "C-c C-c, RET: send the query"
			 :format "(MM) %v"))
    (setq bibslurp/advanced-search-end-year
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'bibslurp/advanced-search-send-query
			 :help-echo "C-c C-c, RET: send the query"
			 :format " (YYYY) %v"))

    ;; Objects
    (setq bibslurp/advanced-search-object
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'newline
			 :help-echo "C-c C-c: send the query; \
RET: insert a newline"
			 :format
			 (concat "\n\n\n"
				 (propertize "Object name/position search"
					     'font-lock-face '(:weight bold))
				 ": %v")))
    ;; Objects catalogs
    (widget-insert "\nSelect data catalogs:\n")
    (setq bibslurp/advanced-search-sim (widget-create 'checkbox t))
    (widget-insert " SIMBAD ")
    (setq bibslurp/advanced-search-ned (widget-create 'checkbox t))
    (widget-insert " NED ")
    (setq bibslurp/advanced-search-adsobj (widget-create 'checkbox t))
    (widget-insert " ADS objects\n")
    ;; Objects logic
    (widget-insert "Combine objects with logic\n")
    (setq bibslurp/advanced-search-object-logic
	  (widget-create 'radio-button-choice
			 :value "OR"
			 '(item "OR") '(item "AND")))

    ;; Title
    (setq bibslurp/advanced-search-title
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'newline
			 :help-echo "C-c C-c: send the query; \
RET: insert a newline"
			 :format
			 (concat "\n\n"
				 (propertize "Enter Title Words"
					     'font-lock-face '(:weight bold))
				 ": %v")))
    ;; Title logic
    (widget-insert "\nCombine with logic\n")
    (setq bibslurp/advanced-search-title-logic
	  (widget-create 'radio-button-choice
			 :value "OR"
			 '(item "OR") '(item "AND")
			 '(item :tag "simple logic" "SIMPLE")
			 '(item :tag "boolean logic" "BOOL")))

    ;; Abstract
    (setq bibslurp/advanced-search-abstract
	  (widget-create 'editable-field
			 :size 13
			 :keymap field-keymap
			 :action 'newline
			 :help-echo "C-c C-c: send the query; \
RET: insert a newline"
			 :format
			 (concat "\n\n"
				 (propertize "Enter Abstract Words/Keywords"
					     'font-lock-face '(:weight bold))
				 ": %v")))
    ;; Abstract logic
    (widget-insert "\nCombine with logic\n")
    (setq bibslurp/advanced-search-abstract-logic
	  (widget-create 'radio-button-choice
			 :value "OR"
			 '(item "OR") '(item "AND")
			 '(item :tag "simple logic" "SIMPLE")
			 '(item :tag "boolean logic" "BOOL")))

    ;; Buttons
    (widget-insert "\n\n")
    (widget-create 'push-button
		   :notify (lambda (&rest _ignore)
			     (bibslurp/advanced-search-send-query))
		   "Send Query")
    (widget-insert " ")
    (widget-create 'push-button
		   :notify (lambda (&rest _ignore)
			     (bibslurp-query-ads-advanced-search))
		   "Clear")

    ;; Setup the widgets
    (use-local-map keymap)
    (widget-setup)

    ;; Move to the author widget
    (widget-forward 4)))

(provide 'bibslurp)

;;; bibslurp.el ends here
