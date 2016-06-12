#lang racket/base
(require "../common/set.rkt"
         "../syntax/syntax.rkt"
         "../syntax/scope.rkt"
         "../syntax/binding.rkt"
         "../expand/env.rkt"
         "../syntax/match.rkt"
         "../common/module-path.rkt"
         "namespace.rkt"
         "module.rkt")

(provide core-stx
         
         add-core-form!
         add-core-primitive!
         
         declare-core-module!
         
         core-module-name
         core-mpi
         core-form-sym)

;; Accumulate all core bindings in `core-scope`, so we can
;; easily generate a reference to a core form using `core-stx`:
(define core-scope (new-multi-scope))
(define core-stx (add-scope empty-syntax core-scope))

(define core-module-name (make-resolved-module-path '#%core))
(define core-mpi (module-path-index-join ''#%core #f))

;; Core forms and primitives are added by `require`s in "expander.rkt"

;; Accumulate added core forms and primitives:
(define core-forms #hasheq())
(define core-primitives #hasheq())

(define (add-core-form! sym proc)
  (add-core-binding! sym)
  (set! core-forms (hash-set core-forms
                             sym
                             proc)))

(define (add-core-primitive! sym val)
  (add-core-binding! sym)
  (set! core-primitives (hash-set core-primitives
                                  sym
                                  val)))

(define (add-core-binding! sym)
  (add-binding! (datum->syntax core-stx sym)
                (make-module-binding core-mpi 0 sym)
                0))

;; Used only after filling in all core forms and primitives:
(define (declare-core-module! ns)
  (declare-module!
   ns
   (make-module #:cross-phase-persistent? #t
                core-mpi
                null
                (hasheqv 0 (for/hasheq ([sym (in-sequences
                                              (in-hash-keys core-primitives)
                                              (in-hash-keys core-forms))])
                             (values sym (make-module-binding core-mpi 0 sym))))
                0 1
                (lambda (ns phase phase-level self bulk-binding-registry)
                  (case phase-level
                    [(0)
                     (for ([(sym val) (in-hash core-primitives)])
                       (namespace-set-variable! ns 0 sym val))]
                    [(1)
                     (for ([(sym proc) (in-hash core-forms)])
                       (namespace-set-transformer! ns 0 sym (core-form proc)))])))
   core-module-name))

;; Helper for recognizing and dispatching on core forms:
(define (core-form-sym s phase)
  (define m (try-match-syntax s '(id . _)))
  (and m
       (let ([b (resolve+shift (m 'id) phase)])
         (and (module-binding? b)
              (eq? core-module-name (module-path-index-resolve (module-binding-module b)))
              (module-binding-sym b)))))