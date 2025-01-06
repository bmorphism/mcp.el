;;; mcp.el --- Model Context Protocol                -*- lexical-binding: t; -*-

;; Copyright (C) 2025  lizqwer scott

;; Author: lizqwer scott <lizqwerscott@gmail.com>
;; Keywords: lisp

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;

;;; Code:

(require 'jsonrpc)

(defconst *MCP-VERSION* "2024-11-05"
  "MCP support version.")

(defclass mcp-process-connection (jsonrpc-process-connection)
  ((-capabilities
    :initform nil
    :accessor mcp--capabilities)
   (-serverinfo
    :initform nil
    :accessor mcp--server-info)
   (-prompts
    :initform nil
    :accessor mcp--prompts)
   (-tools
    :initform nil
    :accessor mcp--tools)
   (-resources
    :initform nil
    :accessor mcp--resources))
  :documentation "A MCP connection over an Emacs process.")

(cl-defmethod initialize-instance :after ((mcp mcp-process-connection) slots)
  (cl-destructuring-bind (&key ((:process proc)) name &allow-other-keys) slots
    (set-process-filter proc #'mcp--process-filter)))

(cl-defmethod jsonrpc-connection-send ((connection mcp-process-connection)
                                       &rest args
                                       &key
                                       id
                                       method
                                       _params
                                       (_result nil result-supplied-p)
                                       error
                                       _partial)
  "Send MESSAGE, a JSON object with no header to CONNECTION."
  (when method
    ;; sanitize method into a string
    (setq args
          (plist-put args :method
                     (cond ((keywordp method) (substring (symbol-name method) 1))
                           ((symbolp method) (symbol-name method))
                           ((stringp method) method)
                           (t (error "[jsonrpc] invalid method %s" method))))))
  (let* ((kind (cond ((or result-supplied-p error) 'reply)
                     (id 'request)
                     (method 'notification)))
         (converted (jsonrpc-convert-to-endpoint connection args kind))
         (json (jsonrpc--json-encode converted)))
    (process-send-string
     (jsonrpc--process connection)
     (format "%s\r\n" json))
    (jsonrpc--event
     connection
     'client
     :json json
     :kind  kind
     :message args
     :foreign-message converted)))

(defvar mcp--in-process-filter nil
  "Non-nil if inside `mcp--process-filter'.")

(cl-defun mcp--process-filter (proc string)
  "Called when new data STRING has arrived for PROC."
  (when mcp--in-process-filter
    ;; Problematic recursive process filters may happen if
    ;; `jsonrpc-connection-receive', called by us, eventually calls
    ;; client code which calls `process-send-string' (which see) to,
    ;; say send a follow-up message.  If that happens to writes enough
    ;; bytes for pending output to be received, we will lose JSONRPC
    ;; messages.  In that case, remove recursiveness by re-scheduling
    ;; ourselves to run from within a timer as soon as possible
    ;; (bug#60088)
    (run-at-time 0 nil #'mcp--process-filter proc string)
    (cl-return-from mcp--process-filter))
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (let* ((conn (process-get proc 'jsonrpc-connection))
             (expected-bytes (jsonrpc--expected-bytes conn)))
        ;; Insert the text, advancing the process marker.
        ;;
        ;; (save-excursion
        ;;   (goto-char (process-mark proc))
        ;;   (let ((inhibit-read-only t)) (insert string))
        ;;   (set-marker (process-mark proc) (point)))
        ;; Loop (more than one message might have arrived)
        ;;
        (unwind-protect
            (let ((message nil)
                  (done nil))
              (let ((messages (split-string string "\n")))
                (dolist (msg messages)
                  (when (not (string-empty-p msg))
                    (setq message
                          (condition-case-unless-debug oops
                              (json-parse-string msg
                                                 :object-type 'plist
                                                 :null-object nil
                                                 :false-object :json-false)
                            (error
                             (jsonrpc--warn "Invalid JSON: %s %s"
                                            (cdr oops) (buffer-string))
                             nil)))
                    (when message
                      (setq message
                            (plist-put message :jsonrpc-json
                                       (buffer-string)))
                      ;; Put new messages at the front of the queue,
                      ;; this is correct as the order is reversed
                      ;; before putting the timers on `timer-list'.
                      (push message
                            (process-get proc 'jsonrpc-mqueue)))))
                (let ((inhibit-read-only t))
                  (delete-region (point-min) (point)))))
          ;; Saved parsing state for next visit to this filter, which
          ;; may well be a recursive one stemming from the tail call
          ;; to `jsonrpc-connection-receive' below (bug#60088).
          ;;
          (setf (jsonrpc--expected-bytes conn) expected-bytes)
          ;; Now, time to notify user code of one or more messages in
          ;; order.  Very often `jsonrpc-connection-receive' will exit
          ;; non-locally (typically the reply to a request), so do
          ;; this all this processing in top-level loops timer.
          (cl-loop
           ;; `timer-activate' orders timers by time, which is an
           ;; very expensive operation when jsonrpc-mqueue is large,
           ;; therefore the time object is reused for each timer
           ;; created.
           with time = (current-time)
           for msg = (pop (process-get proc 'jsonrpc-mqueue)) while msg
           do (let ((timer (timer-create)))
                (timer-set-time timer time)
                (timer-set-function timer
                                    (lambda (conn msg)
                                      (with-temp-buffer
                                        (jsonrpc-connection-receive conn msg)))
                                    (list conn msg))
                (timer-activate timer))))))))

(cl-defun mcp-notify (connection method &optional (params nil))
  "Notify CONNECTION of something, don't expect a reply."
  (apply #'jsonrpc-connection-send
         `(,connection
           :method ,method
           ,@(when params
               (list :params params)))))

(defvar mcp-server-connections (make-hash-table :test #'equal)
  "Mcp server process.")

(defun mcp-request-dispatcher (name method params)
  "Handle mcp server method."
  (message "%s Received request: method=%s, params=%s" name method params))

(defun mcp-notification-dispatcher (name method params)
  "Handle mcp server notification."
  (message "%s Received notification: method=%s, params=%s" name method params))

(defun mcp-on-shutdown (name connection)
  "When mcp server shutdown."
  (message "%s connection shutdown" name))

;;;###autoload
(defun mcp-connect-server (name command args)
  "Connect to an MCP server with the given NAME, COMMAND, and ARGS.

NAME is a string representing the name of the server.
COMMAND is a string representing the command to start the server.
ARGS is a list of arguments to pass to the COMMAND.

This function creates a new process for the server, initializes a connection,
and sends an initialization message to the server. The connection is stored
in the `mcp-server-connections` hash table for future reference."
  (unless (gethash name mcp-server-connections)
    (when-let* ((buffer-name (format "*Mcp %s server*" name))
                (process-name (format "mcp-%s-server" name))
                (process (make-process
                          :name name
                          :command (append (list command)
                                           args)
                          :connection-type 'pipe
                          :coding 'utf-8-emacs-unix
                          ;; :noquery t
                          :stderr (get-buffer-create
                                   (format "*%s stderr*" name))
                          ;; :file-handler t
                          )))
      (let ((connection (make-instance 'mcp-process-connection
                                       :name name
                                       :process process
                                       :request-dispatcher #'(lambda (method params)
                                                               (funcall #'mcp-request-dispatcher name method params))
                                       :notification-dispatcher #'(lambda (method params)
                                                                    (funcall #'mcp-notification-dispatcher name method params))
                                       :on-shutdown #'(lambda (connection)
                                                        (funcall #'mcp-on-shutdown name connection)))))
        ;; Initialize connection
        (puthash name connection mcp-server-connections)
        ;; Send the Initialize message
        (mcp-async-initialize-message connection)))))

;;;###autoload
(defun mcp-stop-server (name)
  "Stop the MCP server with the given NAME.
If the server is running, it will be shutdown and its connection will be removed
from `mcp-server-connections'. If no server with the given NAME is found, a message
will be displayed indicating that the server is not running."
  (if-let* ((connection (gethash name mcp-server-connections)))
      (progn
        (jsonrpc-shutdown connection)
        (setf (gethash name mcp-server-connections) nil))
    (message "mcp %s server not started" name)))

;;;###autoload
(defun mcp-make-text-gptel-tool (name tool-name category)
  "Create a `gptel' tool with the given NAME, TOOL-NAME, and CATEGORY.

NAME is the name of the server connection.
TOOL-NAME is the name of the tool to be created.
CATEGORY is the category under which the tool will be grouped.

Currently, only synchronous messages are supported.

This function retrieves the tool definition from the server connection,
constructs a `gptel' tool with the appropriate properties, and returns it.
The tool is configured to handle input arguments, call the server, and process
the response to extract and return text content."
  (when-let* ((connection (gethash name mcp-server-connections))
              (tools (mcp--tools connection))
              (tool (cl-find tool-name tools :test #'equal :key #'(lambda (tool) (plist-get tool :name)))))
    (cl-destructuring-bind (&key description ((:inputSchema input-schema)) &allow-other-keys) tool
      (cl-destructuring-bind (&key properties required &allow-other-keys) input-schema
        (gptel-make-tool
         :function #'(lambda (&rest args)
                       (when (< (length args) (length required))
                         (error "Error: args not match: %s -> %s" required args))
                       (if-let* ((connection (gethash name mcp-server-connections)))
                           (let* ((need-length (- (/ (length properties) 2)
                                                  (length args)))
                                  (query-args (apply #'append
                                                     (cl-mapcar #'(lambda (arg value)
                                                                    (list (cl-first arg)
                                                                          (if value
                                                                              value
                                                                            (plist-get (cl-second arg) :default))))
                                                                (seq-partition properties 2)
                                                                (append args
                                                                        (when (> need-length 0)
                                                                          (make-list need-length nil)))))))
                             (if-let* ((res (mcp-call-tool connection tool-name query-args))
                                       (contents (plist-get res :content)))
                                 (string-join
                                  (cl-remove-if #'null
                                                (mapcar #'(lambda (content)
                                                            (when (string= "text" (plist-get content :type))
                                                              (plist-get content :text)))
                                                        contents))
                                  "\n")
                               (error "Error: call %s tool error" tool-name)))
                         (error "Error: %s server not connect" name)))
         :name tool-name
         :description description
         :args (mapcar #'(lambda (arg)
                           (let* ((key (cl-first arg))
                                  (value (cl-second arg))
                                  (name (substring (symbol-name key) 1))
                                  (new-value (plist-put value :name name)))
                             (if (plist-member new-value :description)
                                 new-value
                               (plist-put new-value
                                          :description
                                          name))))
                       (seq-partition properties 2))
         :category category)))))

(defun mcp-async-ping (connection)
  "Send an asynchronous ping request to the MCP server via CONNECTION.

The function uses `jsonrpc-async-request' to send a ping request.
On success, it displays a message with the response.
On error, it displays an error message with the code and message from the server."
  (jsonrpc-async-request connection
                         :ping
                         nil
                         :success-fn
                         #'(lambda (res)
                             (message "[mcp] ping success: %s" res))
                         :error-fn (jsonrpc-lambda (&key code message _data)
                                     (message "Sadly, mpc server reports %s: %s"
                                              code message))))

(defun mcp-async-initialize-message (connection)
  "Sending an `initialize' request to the CONNECTION.

CONNECTION is the MCP connection object.

This function sends an `initialize' request to the server
with the client's capabilities and version information."
  (jsonrpc-async-request connection
                         :initialize
                         (list :protocolVersion "2024-11-05"
                               :capabilities '(:roots (:listChanged t))
                               :clientInfo '(:name "mcp-emacs" :version "0.1.0"))
                         :success-fn
                         #'(lambda (res)
                             (cl-destructuring-bind (&key protocolVersion serverInfo capabilities) res
                               (if (string= protocolVersion *MCP-VERSION*)
                                   (progn
                                     (message "[mcp] Connected! Server `MCP (%s)' now managing." (jsonrpc-name connection))
                                     (setf (mcp--capabilities connection) capabilities
                                           (mcp--server-info connection) serverInfo)
                                     ;; Notify server initialized
                                     (mcp-notify connection
                                                 :notifications/initialized)
                                     ;; Get prompts
                                     (when (plist-member capabilities :prompts)
                                       (mcp-async-list-prompts connection))
                                     ;; Get tools
                                     (when (plist-member capabilities :tools)
                                       (mcp-async-list-tools connection))
                                     ;; Get resources
                                     (when (plist-member capabilities :resources)
                                       (mcp-async-list-resources connection)))
                                 (progn
                                   (message "[mcp] Error %s server protocolVersion(%s) not support, client Version: %s."
                                            (jsonrpc-name connection)
                                            protocolVersion
                                            *MCP-VERSION*)
                                   (mcp-stop-server (jsonrpc-name connection))))))
                         :error-fn (jsonrpc-lambda (&key code message _data)
                                     (message "Sadly, mpc server reports %s: %s"
                                              code message))))

(defun mcp-async-list-tools (connection)
  "Get a list of tools from the MCP server using the provided CONNECTION.

CONNECTION is the MCP connection object.

This function sends a request to the server to list available tools.
The result is stored in the `mcp--tools' slot of the CONNECTION object."
  (jsonrpc-async-request connection
                         :tools/list
                         '(:curosr nil)
                         :success-fn
                         #'(lambda (res)
                             (cl-destructuring-bind (&key tools &allow-other-keys) res
                               (setf (mcp--tools connection)
                                     tools)
                               (message "[mcp] tools list success: %s" tools)))
                         :error-fn (jsonrpc-lambda (&key code message _data)
                                     (message "Sadly, mpc server reports %s: %s"
                                              code message))))

(defun mcp-call-tool (connection name arguments)
  "Call a tool on the remote CONNECTION with NAME and ARGUMENTS.

CONNECTION is the MCP connection object.
NAME is the name of the tool to call.
ARGGUMENTS is a list of arguments to pass to the tool."
  (jsonrpc-request connection
                   :tools/call
                   (list :name name
                         :arguments (if arguments
                                        arguments
                                      #s(hash-table)))))

(defun mcp-async-list-prompts (connection)
  "Get list of prompts from the MCP server using the provided CONNECTION.

CONNECTION is the MCP connection object.

The result is stored in the `mcp--prompts' slot of the CONNECTION object."
  (jsonrpc-async-request connection
                         :prompts/list
                         '(:curosr nil)
                         :success-fn
                         #'(lambda (res)
                             (cl-destructuring-bind (&key prompts &allow-other-keys) res
                               (setf (mcp--prompts connection)
                                     prompts)
                               (message "[mcp] prompts list success: %s" prompts)))
                         :error-fn (jsonrpc-lambda (&key code message _data)
                                     (message "Sadly, mpc server reports %s: %s"
                                              code message))))

(defun mcp-async-list-resources (connection)
  "Get list of resources from the MCP server using the provided CONNECTION.

CONNECTION is the MCP connection object.

The result is stored in the `mcp--resources' slot of the CONNECTION object."
  (jsonrpc-async-request connection
                         :resources/list
                         '(:curosr nil)
                         :success-fn
                         #'(lambda (res)
                             (cl-destructuring-bind (&key resources &allow-other-keys) res
                               (setf (mcp--resources connection)
                                     resources)
                               (message "[mcp] resources list success: %s" resources)))
                         :error-fn (jsonrpc-lambda (&key code message _data)
                                     (message "Sadly, mpc server reports %s: %s"
                                              code message))))

(provide 'mcp)
;;; mcp.el ends here
