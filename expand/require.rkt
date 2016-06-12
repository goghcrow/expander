#lang racket/base
(require "../common/set.rkt"
         "../syntax/syntax.rkt"
         "../syntax/scope.rkt"
         "../common/phase.rkt"
         "../syntax/scope.rkt"
         "../syntax/binding.rkt"
         "../syntax/syntax-error.rkt"
         "../namespace/namespace.rkt"
         "../namespace/module.rkt"
         "../syntax/match.rkt"
         "require+provide.rkt"
         "../common/module-path.rkt"
         "../syntax/bulk-binding.rkt")

(provide parse-and-perform-requires!
         perform-initial-require!)

(struct adjust-only (syms))
(struct adjust-prefix (sym))
(struct adjust-all-except (prefix-sym syms))
(struct adjust-rename (to-id from-sym))

(define layers '(raw phaseless path))

(define (parse-and-perform-requires! reqs orig-s self m-ns phase-shift
                                     requires+provides
                                     #:run-phase [run-phase (namespace-phase m-ns)]
                                     #:run? [run? #f]
                                     #:visit? [visit? #t]
                                     #:declared-submodule-names [declared-submodule-names #hasheq()])
  (let loop ([reqs reqs]
             [top-req #f]
             [phase-shift phase-shift]
             [just-meta 'all]
             [adjust #f]
             [for-meta-ok? #t]
             [just-meta-ok? #t]
             [layer 'raw])
    (for ([req (in-list reqs)])
      (define (check-nested want-layer [ok? #t])
        (unless (and ok? (member want-layer (member layer layers)))
          (raise-syntax-error #f "invalid nesting" orig-s req)))
      (define fm (and (pair? (syntax-e req))
                      (identifier? (car (syntax-e req)))
                      (syntax-e (car (syntax-e req)))))
      (case fm
        [(for-meta)
         (check-nested 'raw for-meta-ok?)
         (define m (match-syntax req '(for-meta phase-level spec ...)))
         (define p (syntax-e (m 'phase-level)))
         (unless (phase? p)
           (raise-syntax-error #f "bad phase" orig-s req))
         (loop (m 'spec) 
               (or top-req req)
               (phase+ phase-shift p)
               just-meta
               adjust
               #f just-meta-ok? 'raw)]
        [(for-syntax)
         (check-nested 'raw for-meta-ok?)
         (define m (match-syntax req '(for-syntax spec ...)))
         (loop (m 'spec)
               (or top-req req)
               (phase+ phase-shift 1)
               just-meta
               adjust
               #f just-meta-ok? 'raw)]
        [(for-template)
         (check-nested 'raw for-meta-ok?)
         (define m (match-syntax req '(for-template spec ...)))
         (loop (m 'spec)
               (or top-req req)
               (phase+ phase-shift -1)
               just-meta
               adjust
               #f just-meta-ok? 'raw)]
        [(for-label)
         (check-nested 'raw for-meta-ok?)
         (define m (match-syntax req '(for-label spec ...)))
         (loop (m 'spec)
               (or top-req req)
               (phase+ phase-shift #f)
               just-meta
               adjust
               #f just-meta-ok? 'raw)]
        [(just-meta)
         (check-nested 'raw just-meta-ok?)
         (define m (match-syntax req '(just-meta phase-level spec ...)))
         (define p (syntax-e (m 'phase-level)))
         (unless (phase? p)
           (raise-syntax-error #f "bad phase" orig-s req))
         (loop (m 'spec)
               (or top-req req)
               phase-shift
               just-meta
               adjust
               for-meta-ok? #f 'raw)]
        [(only)
         (check-nested 'phaseless)
         (define m (match-syntax req '(only spec id ...)))
         (loop (list (m 'spec))
               (or top-req req)
               phase-shift
               just-meta
               (adjust-only (ids->sym-set (m 'id)))
               #f #f 'path)]
        [(prefix)
         (check-nested 'phaseless)
         (define m (match-syntax req '(prefix id:prefix spec)))
         (loop (list (m 'spec))
               (or top-req req)
               phase-shift
               just-meta
               (adjust-prefix (syntax-e (m 'id:prefix)))
               #f #f 'path)]
        [(all-except)
         (check-nested 'phaseless)
         (define m (match-syntax req '(all-except spec id ...)))
         (loop (list (m 'spec))
               (or top-req req)
               phase-shift
               just-meta
               (adjust-all-except '|| (ids->sym-set (m 'id)))
               #f #f 'path)]
        [(prefix-all-except)
         (check-nested 'phaseless)
         (define m (match-syntax req '(prefix-all-except id:prefix spec id ...)))
         (loop (list (m 'spec))
               (or top-req req)
               phase-shift
               just-meta
               (adjust-all-except (syntax-e (m 'id:prefix)) (ids->sym-set (m 'id)))
               #f #f 'path)]
        [(rename)
         (check-nested 'phaseless)
         (define m (match-syntax req '(rename spec id:to id:from)))
         (loop (list (m 'spec))
               (or top-req req)
               phase-shift
               just-meta
               (adjust-rename (m 'id:to) (syntax-e (m 'id:from)))
               #f #f 'path)]
        [else
         (define maybe-mp (syntax->datum req))
         (unless (or (module-path? maybe-mp)
                     (resolved-module-path? maybe-mp))
           (raise-syntax-error #f "bad require spec" orig-s req))
         (define mp (if (resolved-module-path? maybe-mp)
                        (resolved-module-path->module-path maybe-mp)
                        maybe-mp))
         (perform-require! mp #f self
                           (or req top-req) m-ns
                           #:phase-shift phase-shift #:run-phase run-phase
                           just-meta adjust
                           requires+provides
                           #:run? run?
                           #:visit? visit?
                           #:declared-submodule-names declared-submodule-names)]))))

(define (ids->sym-set ids)
  (for/set ([id (in-list ids)])
    (syntax-e id)))

;; ----------------------------------------

(define (perform-initial-require! mod-path self
                                  in-stx m-ns
                                  requires+provides)
  (perform-require! mod-path #f self
                    in-stx m-ns
                    #:phase-shift 0 #:run-phase 0
                    'all #f
                    requires+provides
                    #:can-shadow? #t))

;; ----------------------------------------

(define (perform-require! mod-path orig-s self
                          in-stx m-ns
                          #:phase-shift phase-shift #:run-phase run-phase
                          just-meta adjust
                          requires+provides
                          #:visit? [visit? #t]
                          #:run? [run? #f]
                          #:can-shadow? [can-shadow? #f]
                          #:declared-submodule-names [declared-submodule-names #hasheq()])
  (define mpi (if (and (list? mod-path)
                       (= 2 (length mod-path))
                       (eq? 'quote (car mod-path))
                       (symbol? (cadr mod-path))
                       (hash-ref declared-submodule-names (cadr mod-path) #f))
                  (module-path-index-join `(submod "." ,(cadr mod-path)) self)
                  (module-path-index-join mod-path self)))
  (define module-name (module-path-index-resolve mpi #t))
  (define bind-in-stx (if (adjust-rename? adjust)
                          (adjust-rename-to-id adjust)
                          in-stx))
  (define done-syms (make-hash))
  (define m (namespace->module m-ns module-name))
  (unless m (raise-unknown-module-error 'require module-name))
  (define interned-mpi
    (add-required-module! requires+provides mpi phase-shift
                          (module-cross-phase-persistent? m)))
  (bind-all-provides!
   m
   bind-in-stx phase-shift m-ns interned-mpi
   #:only (cond
           [(adjust-only? adjust) (set->list (adjust-only-syms adjust))]
           [(adjust-rename? adjust) (list (adjust-rename-from-sym adjust))]
           [else #f])
   #:can-bulk? (not adjust)
   #:filter (lambda (binding)
              (define sym (module-binding-nominal-sym binding))
              (define provide-phase (module-binding-nominal-phase binding))
              (define adjusted-sym
                (cond
                 [(and (not (eq? just-meta 'all))
                       (not (equal? provide-phase just-meta)))
                  #f]
                 [(not adjust) sym]
                 [(adjust-only? adjust)
                  (and (set-member? (adjust-only-syms adjust) sym)
                       (hash-set! done-syms sym #t)
                       sym)]
                 [(adjust-prefix? adjust)
                  (string->symbol
                   (format "~a~a" (adjust-prefix-sym adjust) sym))]
                 [(adjust-all-except? adjust)
                  (and (not (and (set-member? (adjust-all-except-syms adjust) sym)
                                 (hash-set! done-syms sym #t)))
                       (string->symbol
                        (format "~a~a" (adjust-all-except-prefix-sym adjust) sym)))]
                 [(adjust-rename? adjust)
                  (and (eq? sym (adjust-rename-from-sym adjust))
                       (hash-set! done-syms sym #t)
                       (adjust-rename-to-id adjust))]))
              (when adjusted-sym
                (define s (datum->syntax bind-in-stx adjusted-sym))
                (define bind-phase (phase+ phase-shift provide-phase))
                (check-not-defined #:check-not-required? #t
                                   requires+provides
                                   s bind-phase 
                                   #:unless-matches binding
                                   #:in in-stx)
                (add-defined-or-required-id! requires+provides
                                             s bind-phase binding
                                             #:can-shadow? can-shadow?))
              adjusted-sym))
  (when visit?
    (namespace-module-visit! m-ns interned-mpi phase-shift #:visit-phase run-phase))
  (when run?
    (namespace-module-instantiate! m-ns interned-mpi phase-shift #:run-phase run-phase))
  (when (not (or visit? run?))
    ;; make the module available:
    (namespace-module-make-available! m-ns interned-mpi phase-shift #:visit-phase run-phase))
  ;; check that we covered all expected ids:
  (define need-syms (cond
                    [(adjust-only? adjust)
                     (adjust-only-syms adjust)]
                    [(adjust-all-except? adjust)
                     (adjust-all-except-syms adjust)]
                    [(adjust-rename? adjust)
                     (set (adjust-rename-from-sym adjust))]
                    [else #f]))
  (when (and need-syms
             (not (= (set-count need-syms) (hash-count done-syms))))
    (for ([sym (in-set need-syms)])
      (unless (hash-ref done-syms sym #f)
        (raise-syntax-error #f "not in nested spec" orig-s sym)))))

;; ----------------------------------------

(define (bind-all-provides! m in-stx phase-shift ns mpi
                            #:only only-syms
                            #:can-bulk? can-bulk?
                            #:filter filter)
  (define self (module-self m))
  (for ([(provide-phase-level provides) (in-hash (module-provides m))])
    (define phase (phase+ phase-shift provide-phase-level))
    (for ([sym (in-list (or only-syms (hash-keys provides)))])
      (define out-binding (hash-ref provides sym #f))
      (when out-binding
        (define b (provide-binding-to-require-binding out-binding sym
                                                      #:self self
                                                      #:mpi mpi
                                                      #:provide-phase-level provide-phase-level
                                                      #:phase-shift phase-shift))
        (let-values ([(sym) (filter b)])
          (when (and sym
                     (not can-bulk?)) ;; bulk binding added later
            ;; Add a non-bulk binding, since `filter` has checked/adjusted it
            (add-binding! (datum->syntax in-stx sym) b phase)))))
    ;; Add bulk binding after all filtering
    (when can-bulk?
      (add-bulk-binding! in-stx
                         (bulk-binding provides self mpi provide-phase-level phase-shift
                                       (namespace-bulk-binding-registry ns))
                         phase))))