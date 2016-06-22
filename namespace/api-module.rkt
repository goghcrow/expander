#lang racket/base
(require "../common/module-path.rkt"
         "../expand/root-expand-context.rkt"
         "namespace.rkt"
         (submod "namespace.rkt" for-module)
         "module.rkt"
         (submod "module.rkt" for-module-reflect)
         "../common/contract.rkt")

(provide module-declared?
         module->language-info
         module->namespace
         namespace-unprotect-module)

;; ----------------------------------------

(define (module-declared? mod [load? #f])
  (unless (module-reference? mod)
    (raise-argument-error 'module-declared? module-reference-str mod))
  (define ns (current-namespace))
  (define name (reference->resolved-module-path mod #:load? load?))
  (and (namespace->module ns name) #t))

(define (module->language-info mod [load? #f])
  (unless (module-reference? mod)
    (raise-argument-error 'module->language-info module-reference-str mod))
  (define m (namespace->module/complain 'module->lanuage-info
                                        (current-namespace)
                                        (reference->resolved-module-path mod #:load? load?)))
  (module-language-info m))

(define (module->namespace mod)
  (unless (module-reference? mod)
    (raise-argument-error 'module->namespace module-reference-str mod))
  (define name (reference->resolved-module-path mod #:load? #t))
  (define ns (current-namespace))
  (define phase (namespace-phase ns))
  (define m-ns (namespace->module-namespace ns name phase))
  (unless m-ns
    ;; Check for declaration:
    (namespace->module/complain 'module->namespace ns name)
    ;; Must be declared, but not instantiated
    (raise-arguments-error 'module->namespace
                           "module not instantiated in the current namespace"
                           "name" name))
  (unless (inspector-superior? (current-code-inspector) (namespace-inspector m-ns))
    (raise-arguments-error 'module->namespace
                           "current code inspector cannot access namespace of module"
                           "module name" name))
  (unless (namespace-get-root-expand-ctx m-ns)
    ;; Instantiating the module didn't install a context, so make one now
    (namespace-set-root-expand-ctx! m-ns (make-root-expand-context)))
  ;; Ensure that the module is available
  (namespace-module-make-available! ns (namespace-mpi m-ns) phase)
  m-ns)

(define (namespace-unprotect-module insp mod [ns (current-namespace)])
  (check 'namespace-unprotect-module inspector? insp)
  (check 'namespace-unprotect-module module-path? mod)
  (check 'namespace-unprotect-module namespace? ns)
  (define name (reference->resolved-module-path mod #:load? #f))
  (define phase (namespace-phase ns))
  (define m-ns (namespace->module-namespace ns name phase))
  (unless m-ns
    (raise-arguments-error 'namespace-unprotect-module
                           "module not instantiated"
                           "module name" name))
  (when (inspector-superior? insp (namespace-inspector m-ns))
    (set-namespace-inspector! m-ns (make-inspector (current-code-inspector)))))

;; ----------------------------------------

(define (namespace->module/complain who ns name)
  (or (namespace->module ns name)
      (raise-arguments-error who
                             "unknown module in the current namespace"
                             "name" name)))

;; ----------------------------------------
  
(define (module-reference? mod)
  (or (module-path? mod)
      (module-path-index? mod)
      (resolved-module-path? mod)))

(define module-reference-str
  "(or/c module-path? module-path-index? resolved-module-path?)")

(define (reference->resolved-module-path mod #:load? load?)
  (cond
   [(resolved-module-path? mod) mod]
   [else
    (define mpi (if (module-path-index? mod)
                    mod
                    (module-path-index-join mod #f)))
    (module-path-index-resolve mpi load?)]))