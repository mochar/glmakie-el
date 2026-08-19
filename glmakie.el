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

(defun glmakie-reload ()
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

;;;; Server

(defvar glmakie--process nil)
(defvar glmakie--process-buf-name "*glmakie process*")

(defun glmakie-connect ()
  (let ((process-buf (get-buffer glmakie--process-buf-name)))
    (unless (and process-buf (buffer-live-p process-buf) (process-live-p glmakie--process))
      (setq process-buf (get-buffer-create glmakie--process-buf-name))
      (setq glmakie--process
            (open-network-stream
             "glmakie-process"
             process-buf
             "localhost"
             8888))
      (set-process-filter glmakie--process #'glmakie--server-process-filter))))

(defun glmakie-disconnect ()
  (when (process-live-p glmakie--process)
    (delete-process glmakie--process))
  (when-let ((process-buf (get-buffer glmakie--process-buf-name)))
    (when (buffer-live-p process-buf)
      (kill-buffer process-buf))))

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

(defun glmakie--send-init (id height width)
  (process-send-string
   glmakie--process
   (format "INIT %s %d %d\n" id height width)))

(defun glmakie--send-resize (id height width)
  (process-send-string
   glmakie--process
   (format "RESIZE %s %d %d\n" id height width)))

(defun glmakie--send-mouse-event (btn action id x y)
  (assert (member btn '("LEFT" "RIGHT")))
  (assert (member action '("PRESS" "RELEASE"  "DRAG")))
  (process-send-string
   glmakie--process
   (format "MOUSE %s %s %s %d %d\n" btn action id x y)))

;;;; Canvas

;; The image specification object uniquely (with respect to ‘eq’) identifies a
;; canvas image object.

(cl-defstruct glmakie-figure
  id
  file
  canvas)

;; Key is string id, but id in canvas is symbol!
(defvar glmakie--id->figure (make-hash-table :test #'equal))

(defun glmakie-refresh (canvas)
  (glmakie--update canvas)
  (canvas-refresh canvas))

(cl-defmethod glmakie--process-message ((msg (eql 'INIT)) id height-str width-str)
  (let* ((height (string-to-number height-str))
         (width (string-to-number width-str))
         (id-sym (intern id)) ; `eq' used to identify canvases so must be symbol
         (canvas `(image
                   :type canvas
                   :id ,id-sym
                   :data-width ,width
                   :data-height ,height))
         (file (concat "/dev/shm/" id ".bin" ))
         (fig (make-glmakie-figure :id id :file file :canvas canvas)))
    (if (glmakie--mmap file (* height width))
        (progn
          (puthash id fig glmakie--id->figure)
          (glmakie-refresh canvas))
      (message "GLMakie: Mmap failed"))))

(cl-defmethod glmakie--process-message ((msg (eql 'RESIZE)) id height-str width-str)
  (when-let* ((height (string-to-number height-str))
              (width (string-to-number width-str))
              (figure (gethash id glmakie--id->figure))
              (canvas (oref figure canvas)))
    (setf (plist-get (cdr canvas) :data-height) height
          (plist-get (cdr canvas) :data-width) width)
    (clear-image-cache canvas) ; TODO Necessary?
    (if (glmakie--mmap (oref figure file) (* height width))
        (glmakie-refresh canvas)
      (message "GLMakie: Mmap failed"))))

(cl-defmethod glmakie--process-message ((msg (eql 'REFRESH)) id)
  (when-let* ((figure (gethash id glmakie--id->figure))
              (canvas (oref figure canvas)))
    (glmakie-refresh canvas)))
    
(defun glmakie-init (height width)
  (let* ((id (concat "glmakie-el-" (org-id-uuid))))
    (glmakie--send-init id height width)
    id))

;;;; Actions

(defun glmakie-canvas-drag (e)
  (interactive "e")
  (let* ((tracking t)
         (posn (event-start e))
         (canvas-xy (posn-object-x-y posn))
         (canvas (posn-object posn))
         (canvas-props (cdr canvas))
         (canvas-id (map-elt canvas-props :id))
         (wh (posn-object-width-height posn)))
    (glmakie--send-mouse-event
     "RIGHT" "PRESS"
     canvas-id
     (car canvas-xy) (cdr canvas-xy))
    (track-mouse
      (while tracking
        (let ((ev (read-event)))
          (cond
           ((eq (car-safe ev) 'mouse-movement)
            (let* ((posn (event-end ev))
                   (canvas-xy (posn-object-x-y posn))
                   (img (posn-object posn)))
              ;; TODO When mouse drags outside canvas bounds (img=nil) we can
              ;; use "wh" to continue sending drag events
              (when img
                (message "Dragging on %s at X: %d, Y: %d" img (car canvas-xy) (cdr canvas-xy))
                (glmakie--send-mouse-event
                 "RIGHT" "DRAG"
                 canvas-id
                 (car canvas-xy) (cdr canvas-xy))
              )))
           
           ((memq (car-safe ev) '(mouse-1 drag-mouse-1 up-mouse-1)) ; Drag ended
            (setq tracking nil)
            (let* ((posn (event-end ev))
                   (canvas-xy (posn-object-x-y posn)))
              (glmakie--send-mouse-event
               "RIGHT" "RELEASE"
               canvas-id
               (car canvas-xy) (cdr canvas-xy))))
           
           (t
            (setq unread-command-events (cons ev unread-command-events))
            (setq tracking nil))))))))

(defvar-keymap glmakie-map
  "<down-mouse-1>" 'glmakie-canvas-drag
  "g" 'glmakie--send-reset
  )


;;;; Scratch

(when nil
  (progn
    (glmakie-reload)
    (glmakie-connect)
    )

  (setq glmakie-canvas-id (glmakie-init 300 200))
  (setq glmakie-canvas-fig (gethash glmakie-canvas-id glmakie--id->figure))
  (setq glmakie-canvas (oref glmakie-canvas-fig canvas))

  (clear-image-cache glmakie-canvas)

  (glmakie--send-resize
   glmakie-canvas-id
   300 600
   )

  (glmakie-refresh glmakie-canvas)

  (insert "\n" (propertize "#" 'display glmakie-canvas 'keymap glmakie-map))
  #
  )

;;;; Footer

(provide 'glmakie)

;;; glmakie.el ends here
