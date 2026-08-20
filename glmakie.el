;;; glmakie.el --- Emacs frontend for GLMakie -*- lexical-binding: t -*-

;; URL: https://github.com/mochar/glmakie-el
;; Package-Requires: ((emacs "26.2"))
;; Version: 0.0.1
;; Created: 2026-08-19

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Interactive frontend for Julia's GLMakie plotting package using the canvas
;; feature released in Emacs 32.

;;; Code:

;;;; Requires

(require 'cl-lib)
(require 'map)

;;;; Module

(defun glmakie--reload-module ()
  "Hack that copies the so file to a unique name and loads that as a module.
Note that this does not unload the previous loaded objects."
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

;;;; Figure

(cl-defstruct glmakie-figure
  ;; String identifier.
  id
  ;; Marker to charachter position in which canvas is displayed.
  marker
  ;; Path to the shared memory file that is used for mmap buffer.
  file
  ;; Image object specification used by emacs to config and identify the canvas.
  ;; Emacs identifies images uniquely through this spec (with ‘eq’). For this
  ;; reason the :id property in the canvas object is a symbol.
  canvas
  ;; Emacs C pointer container for the C module to work with the buffer.
  buf-ptr
  )

(defun glmakie--make-figure (&optional size)
  (let* ((id (concat "glmakie-el-" (org-id-uuid)))
         (id-sym (intern id)) ; `eq' used to identify canvases so must be symbol
         (size (or size '(300 . 300)))
         (canvas `(image
                   :type canvas
                   :id ,id-sym
                   :data-width ,(car size)
                   :data-height ,(cdr size)))
         (file (concat "/dev/shm/" id ".bin" ))
         (fig (make-glmakie-figure
               :id id :file file :canvas canvas)))
    (puthash id fig glmakie--id->figure)
    fig))

(defun glmakie--figure-resolve (fig/canvas/id)
  "Return FIG/CANVAS/ID as `glmakie-figure' object. Can be ID (string/symbol), canvas
object, or the figure itself."
  (cond
   ((glmakie-figure-p fig/canvas/id)
    fig/canvas/id)
   ((symbolp fig/canvas/id)
    (gethash (symbol-name fig/canvas/id) glmakie--id->figure))
   ((stringp fig/canvas/id)
    (gethash fig/canvas/id glmakie--id->figure))
   ((and (consp fig/canvas/id)
         (eq (car fig/canvas/id) 'image)
         (plistp (cdr fig/canvas/id)))
    (when-let ((id (map-elt (cdr fig/canvas/id) :id)))
      (gethash (symbol-name id) glmakie--id->figure)))))

(defun glmakie-figure-at-point (&optional id)
  "Return `glmakie-figure' of the glmakie canvas image at point."
  (when (image-at-point-p)
    (when-let ((fig (glmakie--figure-resolve (image--get-image))))
      (when (or (null id) (string= id (glmakie-figure-id fig)))
          fig))))

(defun glmakie-refresh (fig/canvas/id)
  "Read the color buffer from the mmaped file and refresh the canvas."
  (when-let* ((fig (glmakie--figure-resolve fig/canvas/id))
              (buf-ptr (glmakie-figure-buf-ptr fig))
              (canvas (glmakie-figure-canvas fig)))
    (glmakie--read buf-ptr canvas)
    (canvas-refresh canvas)))

;;;; Variables

;; Key is string id, but id in canvas is symbol!
(defvar glmakie--id->figure (make-hash-table :test #'equal)
  "Maps canvas ID (string) to canvas object of all canvases.")

;; Server process
(defvar glmakie--process nil)
(defvar glmakie--process-buf-name "*glmakie process*")


;;;; Utilities

(defun glmakie--server-live-p ()
  "Return non-nil if the TCP server is live and running."
  (when-let ((process-buf (get-buffer glmakie--process-buf-name)))
    (and process-buf
         (buffer-live-p process-buf)
         (process-live-p glmakie--process))))

(defun glmakie--delete-figure (fig/canvas/id)
  "Delete the glmakie figure.

Note that the shared memory buffer is unmapped and the C struct
deallocated when the buf-ptr stored in the figure is garbage
collected. Therefore global references made to this struct will prevent
this from happening."
  (let* ((fig (glmakie--figure-resolve fig/canvas/id))
         (canvas (glmakie-figure-canvas fig))
         (id (glmakie-figure-id fig)))
    ;; Delete the char that holds the canvas
    (when-let* ((marker (glmakie-figure-marker fig))
                (buf (marker-buffer marker))
                (pos (marker-position marker)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (save-excursion
            (goto-char pos)
            (when-let ((fig (glmakie-figure-at-point id)))
              (delete-region pos (1+ pos)))))))
    ;; Delete
    (image-flush canvas t)
    (when (glmakie--server-live-p)
      (glmakie--send-close id))
    (remhash id glmakie--id->figure)))

(defun glmakie--cleanup ()
  (unless (hash-table-empty-p glmakie--id->figure)
    ;; glmakie--delete-figure removes it from the hashtable so not sure if its
    ;; safe to use maphash. instead get keys first and loop.
    (dolist (fig (hash-table-values glmakie--id->figure))
      (glmakie--delete-figure fig))
    ;; why not
    (clrhash glmakie--id->figure)))

(defun glmakie--capture-julia-code (&optional initial-code)
  "Popup a julia-mode buffer and return its contents."
  (let* ((buf (generate-new-buffer "*glmakie-capture*"))
         (original-window-config (current-window-configuration))
         result)
    
    (with-current-buffer buf
      (julia-ts-mode)
      ;; TODO Getting some problems with julia-snail mode
      (when (bound-and-true-p julia-snail-mode)
        (julia-snail-mode -1))
      (if initial-code
          (insert initial-code)
        (insert "lines(sin.(1:100))"))
      
      (local-set-key (kbd "C-c C-c") #'exit-recursive-edit)
      (local-set-key (kbd "C-c C-k") #'abort-recursive-edit)
      (setq header-line-format 
            (propertize " Press C-c C-c to finish, C-c C-k to cancel. " 'face 'highlight)))

    (pop-to-buffer buf)

    ;; Enter recursive edit to block execution and wait for the user
    (condition-case nil
        (progn
          (recursive-edit)
          ;; User pressed C-c C-c
          (setq result (with-current-buffer buf (buffer-string))))
      ;; User pressed C-c C-k 
      (quit (setq result nil)))

    ;; Cleanup
    (kill-buffer buf)
    (set-window-configuration original-window-config)
    result))

;;;; Server

;; A connection is established to a TCP server run in Julia to instruct it to
;; make, update, and send events to GLMakie figures. Whenever such a request has
;; been handled, Julia will send a message back telling us what happened to the
;; figure and that the colorbuffer must be reread to update the figure.

(defun glmakie-connect ()
  "Create a TCP network stream to the Julia server."
  (if (glmakie--server-live-p)
      (message "Already connected")
    (setq glmakie--process
          (open-network-stream
           "glmakie-process"
           (get-buffer-create glmakie--process-buf-name)
           "localhost"
           8888))
    (set-process-filter glmakie--process #'glmakie--server-process-filter)
    (set-process-sentinel glmakie--process #'glmakie--server-process-sentinel)))

(defun glmakie-disconnect ()
  "Disconnect the Julia TCP stream.
This also deletes all figures that have been made, as Julia will do so
too when the connection is lost."
  (glmakie--cleanup)
  (when (process-live-p glmakie--process)
    (delete-process glmakie--process))
  (when-let ((process-buf (get-buffer glmakie--process-buf-name)))
    (when (buffer-live-p process-buf)
      (kill-buffer process-buf))))

(defun glmakie--server-process-sentinel (proc event)
  (pcase (s-trim event)
    ("connection broken by remote peer"
     (glmakie-disconnect)
     (message "GLMakie: Disconnected"))
    ("deleted"
     (message "GLMakie: Closed"))
    (_
     (message "GLMakie: Unprocessed event: %s" event))))

;; Julia messages start with a command. We dispatch `glmakie--process-message'
;; methods on the interned command string.
(cl-defgeneric glmakie--process-message (msg &rest args)
  (message "GLMakie: Unrecognized message: %s (%s)" msg args))

(defun glmakie--server-process-filter (proc str)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert str)
      (set-marker (process-mark proc) (point))
      (dolist (cmd (s-split "\n" str))
        (when (and cmd (not (string-empty-p cmd)))
          (let ((parts (s-split " " cmd)))
            (apply 'glmakie--process-message (intern (car parts)) (cdr parts))))))))

(defun glmakie--send-cmd (cmd)
  "Send CMD string to Julia."
  (when (glmakie--server-live-p)
    (process-send-string
     glmakie--process
     (concat cmd "\n"))))

(defun glmakie--send-init (id height width)
  "Tell Julia to make a new GLMakie figure."
  (glmakie--send-cmd
   (format "INIT %s %d %d" id height width)))

(defun glmakie--send-close (id)
  "Tell Julia to close and cleanup a figure."
  (glmakie--send-cmd
   (format "CLOSE %s" id)))

(defun glmakie--send-resize (id height width)
  "Tell Julia to resize a figure."
  (glmakie--send-cmd
   (format "RESIZE %s %d %d" id height width)))

(defun glmakie--send-mouse-event (btn action id x y)
  "Send a mouse event."
  (assert (member btn '("LEFT" "RIGHT")))
  (assert (member action '("PRESS" "RELEASE" "DRAG")))
  (glmakie--send-cmd
   (format "MOUSE %s %s %s %d %d" btn action id x y)))

(defun glmakie--send-key-event (btn action id)
  "Send a keyboard event."
  (assert (member action '("PRESS" "RELEASE" "REPEAT")))
  (glmakie--send-cmd
   (format "KEY %s %s %s" btn action id)))

(defun glmakie--send-reset-limits (id)
  "Tell julia to reset the limits of a figure.
This actually just sends a control-left click event."
  (glmakie--send-key-event "LEFT_CONTROL" "PRESS" id)
  (glmakie--send-mouse-event "LEFT" "PRESS" id 150 150)
  (glmakie--send-mouse-event "LEFT" "RELEASE" id 150 150)
  (glmakie--send-key-event "LEFT_CONTROL" "RELEASE" id))

;;;; Canvas

(cl-defmethod glmakie--process-message ((msg (eql 'INIT)) id height-str width-str)
  "Create a `glmakie-figure' and stores it in `glmakie--id->figure'."
  (if-let* ((fig (gethash id glmakie--id->figure))
            (canvas (glmakie-figure-canvas fig))
            (height (string-to-number height-str))
            (width (string-to-number width-str)))
      (if-let* ((buf-ptr (glmakie--init (glmakie-figure-file fig) (* height width))))
          (progn
            (setf (plist-get (cdr canvas) :data-height) height
                  (plist-get (cdr canvas) :data-width) width
                  (glmakie-figure-buf-ptr fig) buf-ptr)
            (glmakie-refresh fig))
        (warn "GLMakie: Mmap failed"))
    (warn "GLMakie: Figure created but not found in emacs")))

(cl-defmethod glmakie--process-message ((msg (eql 'RESIZE)) id height-str width-str)
  (when-let* ((height (string-to-number height-str))
              (width (string-to-number width-str))
              (figure (gethash id glmakie--id->figure))
              (buf-ptr (glmakie-figure-buf-ptr figure))
              (canvas (glmakie-figure-canvas figure)))
    (setf (plist-get (cdr canvas) :data-height) height
          (plist-get (cdr canvas) :data-width) width)
    (clear-image-cache canvas) ; TODO Necessary?
    (if (glmakie--resize buf-ptr (* height width))
        (glmakie-refresh figure)
      (message "GLMakie: Mmap failed"))))

(cl-defmethod glmakie--process-message ((msg (eql 'REFRESH)) id)
  (when-let* ((figure (gethash id glmakie--id->figure)))
    (glmakie-refresh figure)))

(defun glmakie--canvas-modification-hook (start end)
  "Hook run when character holding canvas is deleted, ask user to delete figure."
  (when (> end start)
    (when-let ((fig (glmakie-figure-at-point)))
      (when (yes-or-no-p "Delete Makie plot?")
        (let ((inhibit-modification-hooks t))
        (glmakie--delete-figure fig))))))

(defun glmakie--insert-canvas (canvas &optional pos)
  (save-excursion
    (if pos
        (goto-char pos)
      (move-end-of-line 1)
      (insert "\n"))
    (prog1 (point-marker)
      (insert
       (propertize
        (or comment-start "#")
        'display canvas
        'keymap glmakie-map
        'modification-hooks (list #'glmakie--canvas-modification-hook)
        )))))

(defun glmakie--resize-delta (side how &optional px)
  (assert (member side '(:height :width)))
  (assert (member how '(:inc :dec)))
  (if-let* ((canvas (image--get-image))
            (px (or px current-prefix-arg 30))
            (f (if (eq how :inc) #'+ #'-)))
      (map-let (:id :data-height :data-width) (cdr canvas)
        (glmakie--send-resize
         (symbol-name id)
         (max 1 (funcall f data-height (if (eq side :height) px 0)))
         (max 1 (funcall f data-width (if (eq side :width) px 0)))))
    (user-error "No canvas at point")))

;;;; Actions

(defun glmakie--mouse-down-event (e)
  (interactive "e")
  (let* ((tracking t)
         (btn (if (eq (car e) 'down-mouse-1) "LEFT" "RIGHT"))
         (posn (event-start e))
         (canvas-xy (posn-object-x-y posn))
         (canvas (posn-object posn))
         (canvas-props (cdr canvas))
         (canvas-id (map-elt canvas-props :id))
         (wh (posn-object-width-height posn)))
    (glmakie--send-mouse-event
     btn "PRESS"
     canvas-id
     (car canvas-xy) (cdr canvas-xy))
    (track-mouse
      (while tracking
        (let ((ev (read-event)))
          (if (eq (car-safe ev) 'mouse-movement)
              (let* ((posn (event-end ev))
                     (canvas-xy (posn-object-x-y posn))
                     (img (posn-object posn)))
                ;; TODO When mouse drags outside canvas bounds (img=nil) we can
                ;; use "wh" to continue sending drag events
                (when img
                  (message "Dragging on %s at X: %d, Y: %d" img (car canvas-xy) (cdr canvas-xy))
                  (glmakie--send-mouse-event
                   btn "DRAG"
                   canvas-id
                   (car canvas-xy) (cdr canvas-xy))
                  ))
            
            (setq tracking nil)

            (let* ((drag-end-p (memq (car-safe ev) '(mouse-1 drag-mouse-1 up-mouse-1)))
                   (posn (event-end ev))
                   (canvas-xy (posn-object-x-y posn)))
              (glmakie--send-mouse-event
               btn "RELEASE"
               canvas-id
               (car canvas-xy) (cdr canvas-xy))
              
              (unless drag-end-p
                (setq unread-command-events (cons ev unread-command-events))))))))))

(defun glmakie--keyboard-event ()
  (interactive)
  (let ((fig (glmakie-figure-at-point)))
    (message "%s" fig)))

(defun glmakie-reset-limits ()
  (interactive)
  (let* ((canvas (image--get-image))
         (canvas-props (cdr canvas))
         (canvas-id (map-elt canvas-props :id)))
    (glmakie--send-reset-limits canvas-id)))

(defvar-keymap glmakie-map
  "<down-mouse-1>" 'glmakie--mouse-down-event
  "<down-mouse-3>" 'glmakie--mouse-down-event
  "l" 'glmakie-reset-limits
  ;; "<t>" 'glmakie--keyboard-event
  "<right>" (lambda () (interactive) (glmakie--resize-delta :width :inc))
  "<left>" (lambda () (interactive) (glmakie--resize-delta :width :dec))
  "<up>" (lambda () (interactive) (glmakie--resize-delta :height :dec))
  "<down>" (lambda () (interactive) (glmakie--resize-delta :height :inc))
  )

;;;; Commands

(defun glmakie-insert-new-figure ()
  (interactive)
  (let* ((code (if (region-active-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (glmakie--capture-julia-code)))
         (fig (glmakie--make-figure))
         (canvas (glmakie-figure-canvas fig))
         (marker (glmakie--insert-canvas canvas)))
    (setf (glmakie-figure-marker fig) marker)
    (glmakie--send-init (glmakie-figure-id fig)
                        (plist-get (cdr canvas) :data-height)
                        (plist-get (cdr canvas) :data-width))))

(defun glmakie-figures ()
  "View all figures in a buffer."
  (interactive)
  (let ((buf (get-buffer-create "*glmakie figures*")))
    (with-current-buffer buf
      (delete-region (point-min) (point-max))
      (goto-char (point-min))
      (if (hash-table-empty-p glmakie--id->figure)
          (insert (propertize "No figures" 'face 'Info-quoted))
        (dolist (fig (hash-table-values glmakie--id->figure))
          (glmakie--insert-canvas (glmakie-figure-canvas fig) (point))
          (move-end-of-line 1)
          (insert "\n"))
        (goto-char (point-min))))
    (pop-to-buffer buf)))

;;;; Scratch

(when nil
  (glmakie--reload-module)

  (glmakie-connect)

  (glmakie-disconnect) 

  (glmakie-insert-new-figure)

  )

;;;; Footer

(provide 'glmakie)

;;; glmakie.el ends here
