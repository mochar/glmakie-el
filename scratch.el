

;;; Module

(defun glmakie-reload ()
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

;;; Server

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

      (let ((parts (s-split " " str)))
        (apply 'glmakie--process-message (intern (car parts)) (cdr parts))))))

(defun glmakie--send-init (id height width)
  (process-send-string
   glmakie--process
   (format "INIT %s %d %d\n" id height width)))

(defun glmakie--send-resize (id height width)
  (process-send-string
   glmakie--process
   (format "RESIZE %s %d %d\n" id height width)))

;;; Canvas

;; The image specification object uniquely (with respect to ‘eq’) identifies a
;; canvas image object.

(cl-defstruct glmakie-figure
  id
  file
  canvas)

;; Key is string id, but id in canvas is symbol!
(defvar glmakie--id->figure (make-hash-table :test #'equal))

(cl-defmethod glmakie--process-message ((msg (eql 'INIT)) id height-str width-str)
  (message (concat id height-str width-str))
  ;; (edebug)
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
        (puthash id fig glmakie--id->figure)
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
        (progn
          (glmakie--update canvas)
          (canvas-refresh canvas))
      (message "GLMakie: Mmap failed"))))

(defun glmakie-init (height width)
  (let* ((id (concat "glmakie-el-" (org-id-uuid))))
    (glmakie--send-init id height width)
    id))

;; (defun glmakie-resize (height width)
;;   (setf (plist-get (cdr glmakie-canvas) :data-height) height
;;         (plist-get (cdr glmakie-canvas) :data-width) width)
;;   (glmakie--send-resize height width))

;; (defun glmakie-resize-to-window ()
;;   (glmakie-resize
;;    (window-pixel-height)
;;    (window-pixel-width)))


;;; Scratch

(progn
  (glmakie-reload)
  (glmakie-connect)
  )

(setq glmakie-canvas-id (glmakie-init 300 200))
(setq glmakie-canvas-fig (gethash glmakie-canvas-id glmakie--id->figure))
(setq glmakie-canvas (oref glmakie-canvas-fig canvas))

(clear-image-cache glmakie-canvas)

(glmakie--send-resize
 (format "%s" (plist-get (cdr glmakie-canvas) :id))
 300 600
 )

(progn
  (glmakie--update glmakie-canvas)
  (canvas-refresh glmakie-canvas)
  )


(insert "\n" (propertize "#" 'display glmakie-canvas))
#

