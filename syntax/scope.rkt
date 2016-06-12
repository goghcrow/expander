#lang racket/base
(require "../common/set.rkt"
         "../compile/serialize-property.rkt"
         "../compile/serialize-state.rkt"
         "../common/memo.rkt"
         "syntax.rkt"
         "../common/phase.rkt"
         "fallback.rkt"
         "datum-map.rkt")

(provide new-scope
         new-multi-scope
         add-scope
         add-scopes
         remove-scope
         remove-scopes
         flip-scope
         flip-scopes
         push-scope
         
         syntax-e ; handles lazy scope propagation
         
         syntax-scope-set
         syntax-any-macro-scopes?
         
         syntax-shift-phase-level

         syntax-swap-scopes

         add-binding!
         add-bulk-binding!
         
         prop:bulk-binding
         (struct-out bulk-binding-class)

         resolve

         bound-identifier=?

         top-level-common-scope

         deserialize-scope
         deserialize-scope-fill!
         deserialize-representative-scope
         deserialize-representative-scope-fill!
         deserialize-multi-scope
         deserialize-shifted-multi-scope
         deserialize-bulk-binding-at
         
         generalize-scope)

(module+ for-debug
  (provide (struct-out scope)
           (struct-out multi-scope)
           (struct-out representative-scope)
           (struct-out bulk-binding-at)
           bulk-binding-symbols
           bulk-binding-create
           scope-set-at-fallback))

;; A scope represents a distinct "dimension" of binding. We can attach
;; the bindings for a set of scopes to an arbitrary scope in the set;
;; we pick the most recently allocated scope to make a binding search
;; faster and to improve GC, since non-nested binding contexts will
;; generally not share a most-recent scope.

(struct scope (id             ; internal scope identity; used for sorting
               kind           ; debug info
               [bindings #:mutable]       ; sym -> scope-set -> binding [shadows any bulk binding]
               [bulk-bindings #:mutable]) ; list of bulk-binding-at [earlier shadows later]
        ;; Custom printer:
        #:property prop:custom-write
        (lambda (sc port mode)
          (write-string "#<scope:" port)
          (display (scope-id sc) port)
          (write-string ":" port)
          (display (scope-kind sc) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (s ser state)
          (unless (set-member? (serialize-state-reachable-scopes state) s)
            (error "internal error: found supposedly unreachable scope"))
          (if (eq? s top-level-common-scope)
              `(deserialize-scope)
              `(deserialize-scope ,(ser (scope-kind s)))))
        #:property prop:serialize-fill!
        (lambda (id s ser state)
          (if (and (empty-bindings? (scope-bindings s))
                   (empty-bulk-bindings? (scope-bulk-bindings s)))
              `(void)
              `(deserialize-scope-fill!
                ,id
                ,(ser (prune-bindings-to-reachable (scope-bindings s)
                                                   state))
                ,(ser (prune-bulk-bindings-to-reachable (scope-bulk-bindings s)
                                                        state)))))
        #:property prop:reach-scopes
        (lambda (s reach)
          ;; the `bindings` field is handled via `prop:scope-with-bindings`
          (void))
        #:property prop:scope-with-bindings
        (lambda (s reachable-scopes reach register-trigger)
          (when (scope-bindings s)
            (register-bindings-reachable (scope-bindings s)
                                         reachable-scopes
                                         reach
                                         register-trigger))))

(define deserialize-scope
  (case-lambda
    [() top-level-common-scope]
    [(kind)
     (scope (new-deserialize-scope-id!) kind (make-bindings) (make-bulk-bindings))]))

(define (deserialize-scope-fill! s bindings bulk-bindings)
  (set-scope-bindings! s bindings)
  (set-scope-bulk-bindings! s bulk-bindings))

;; A "multi-scope" represents a group of scopes, each of which exists
;; only at a specific phase, and each in a distinct phase. This
;; infinite group of scopes is realized on demand. A multi-scope is
;; used to represent the inside of a module, where bindings in
;; different phases are distinguished by the different scopes within
;; the module's multi-scope.
;;
;; To compute a syntax's set of scopes at a given phase, the
;; phase-specific representative of the multi scope is combined with
;; the phase-independent scopes. Since a multi-scope corresponds to
;; a module, the number of multi-scopes in a syntax is expected to
;; be small.
(struct multi-scope (id       ; identity
                     name     ; for debugging
                     scopes)  ; phase -> representative-scope
        #:property prop:serialize
        (lambda (ms ser state)
          `(deserialize-multi-scope
            ,(ser (multi-scope-name ms))
            ,(ser (multi-scope-scopes ms))))
        #:property prop:reach-scopes
        (lambda (ms reach)
          (reach (multi-scope-scopes ms))))

(define (deserialize-multi-scope name scopes)
  (multi-scope (new-deserialize-scope-id!) name scopes))

(struct representative-scope scope (owner   ; a multi-scope for which this one is a phase-specific identity
                                    phase)  ; phase of this scope
        #:mutable ; to support serialization
        #:property prop:custom-write
        (lambda (sc port mode)
          (write-string "#<scope:" port)
          (display (scope-id sc) port)
          (when (representative-scope-owner sc)
            (write-string "=" port)
            (display (multi-scope-id (representative-scope-owner sc)) port))
          (write-string "@" port)
          (display (representative-scope-phase sc) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (s ser state)
          `(deserialize-representative-scope
            ,(ser (scope-kind s))
            ,(ser (representative-scope-phase s))))
        #:property prop:serialize-fill!
        (lambda (id s ser state)
          `(deserialize-representative-scope-fill!
            ,id
            ,(ser (prune-bindings-to-reachable (scope-bindings s)
                                               state))
            ,(ser (prune-bulk-bindings-to-reachable (scope-bulk-bindings s)
                                                    state))
            ,(ser (representative-scope-owner s))))
        #:property prop:reach-scopes
        (lambda (s reach)
          ;; the inherited `bindings` field is handled via `prop:scope-with-bindings`
          (reach (representative-scope-owner s))))

(define (deserialize-representative-scope kind phase)
  (representative-scope (new-deserialize-scope-id!) kind #f #f #f phase))

(define (deserialize-representative-scope-fill! s bindings bulk-bindings owner)
  (deserialize-scope-fill! s bindings bulk-bindings)
  (set-representative-scope-owner! s owner))

(struct shifted-multi-scope (phase        ; phase shift applies to all scopes in multi-scope
                             multi-scope) ; a multi-scope
        #:transparent
        #:property prop:custom-write
        (lambda (sms port mode)
          (write-string "#<scope:" port)
          (display (multi-scope-id (shifted-multi-scope-multi-scope sms)) port)
          (write-string "@" port)
          (display (shifted-multi-scope-phase sms) port)
          (write-string ">" port))
        #:property prop:serialize
        (lambda (sms ser state)
          `(deserialize-shifted-multi-scope
            ,(ser (shifted-multi-scope-phase sms))
            ,(ser (shifted-multi-scope-multi-scope sms))))
        #:property prop:reach-scopes
        (lambda (sms reach)
          (reach (shifted-multi-scope-multi-scope sms))))

(define (deserialize-shifted-multi-scope phase multi-scope)
  (shifted-multi-scope phase multi-scope))

(struct bulk-binding-at (scopes ; scope set
                         bulk)  ; bulk-binding
        #:property prop:serialize
        (lambda (bba ser state)
          `(deserialize-bulk-binding-at
            ,(ser (bulk-binding-at-scopes bba))
            ,(ser (bulk-binding-at-bulk bba))))
        #:property prop:reach-scopes
        (lambda (sms reach)
          ;; bulk bindings are pruned dependong on whether all scopes
          ;; in `scopes` are reachable, and we shouldn't get here
          ;; when looking for scopes
          (error "shouldn't get here")))

(define (deserialize-bulk-binding-at scopes bulk)
  (bulk-binding-at scopes bulk))

;; Bulk bindings are represented by a property, so that the implementation
;; can be separate and manage serialiation:
(define-values (prop:bulk-binding bulk-binding? bulk-binding-ref)
  (make-struct-type-property 'bulk-binding))

;; Value of `prop:bulk-binding`
(struct bulk-binding-class (get-symbols ; bulk-binding list-of-shift -> sym -> binding-info
                            create))    ; bul-binding -> binding-info sym -> binding
(define (bulk-binding-symbols b s extra-shifts)
  ;; Providing the identifier `s` supports its shifts
  ((bulk-binding-class-get-symbols (bulk-binding-ref b))
   b 
   (append extra-shifts (if s (syntax-mpi-shifts s) null))))
(define (bulk-binding-create b)
  (bulk-binding-class-create (bulk-binding-ref b)))

;; Each new scope increments the counter, so we can check whether one
;; scope is newer than another.
(define id-counter 0)
(define (new-scope-id!)
  (set! id-counter (add1 id-counter))
  id-counter)

(define (new-deserialize-scope-id!)
  ;; negative scope ensures that new scopes are recognized as such by
  ;; having a larger id
  (- (new-scope-id!)))

(define (make-bindings)
  #hasheq())

(define (empty-bindings? bs)
  (zero? (hash-count bs)))

(define (make-bulk-bindings)
  null)

(define (empty-bulk-bindings? bbs)
  (null? bbs))

;; A shared "outside-edge" scope for all top-level contexts
(define top-level-common-scope (scope 0 'module (make-bindings) (make-bulk-bindings)))

(define (new-scope kind)
  (scope (new-scope-id!) kind (make-bindings) (make-bulk-bindings)))

(define (new-multi-scope [name #f])
  (shifted-multi-scope 0 (multi-scope (new-scope-id!) name (make-hasheqv))))

(define (multi-scope-to-scope-at-phase ms phase)
  ;; Get the identity of `ms` at phase`
  (or (hash-ref (multi-scope-scopes ms) phase #f)
      (let ([s (representative-scope (new-scope-id!) 'module
                                     (make-bindings) (make-bulk-bindings)
                                     ms phase)])
        (hash-set! (multi-scope-scopes ms) phase s)
        s)))

(define (scope>? sc1 sc2)
  ((scope-id sc1) . > . (scope-id sc2)))

;; Adding, removing, or flipping a scope is propagated
;; lazily to subforms
(define (apply-scope s sc op prop-op)
  (if (shifted-multi-scope? sc)
      (apply-shifted-multi-scope s sc op)
      (struct-copy syntax s
                   [scopes (op (syntax-scopes s) sc)]
                   [scope-propagations (and (datum-has-elements? (syntax-content s))
                                            (prop-op (syntax-scope-propagations s)
                                                     sc
                                                     (syntax-scopes s)))])))

;; Non-lazy application of a shifted multi scope;
;; since this kind of scope is only added for modules,
;; it's not worth making it lazy
(define (apply-shifted-multi-scope s sms op)
  (define-memo-lite (do-op smss)
    (fallback-update-first
     smss
     (lambda (smss) (op smss sms))))
  (syntax-map s
              (lambda (tail? x) x)
              (lambda (s d)
                (struct-copy syntax s
                             [content d]
                             [shifted-multi-scopes
                              (do-op (syntax-shifted-multi-scopes s))]))
              syntax-e))

(define (syntax-e s)
  (define prop (syntax-scope-propagations s))
  (if prop
      (let ([new-content
             (syntax-map (syntax-content s)
                         (lambda (tail? x) x)
                         (lambda (sub-s d)
                           (struct-copy syntax sub-s
                                        [scopes (propagation-apply
                                                 prop
                                                 (syntax-scopes sub-s)
                                                 s)]
                                        [scope-propagations (propagation-merge
                                                             prop
                                                             (syntax-scope-propagations sub-s)
                                                             (syntax-scopes sub-s))]))
                         #f)])
        (set-syntax-content! s new-content)
        (set-syntax-scope-propagations! s #f)
        new-content)
      (syntax-content s)))

;; When a representative-scope is manipulated, we want to
;; manipulate the multi scope, instead (at a particular
;; phase shift)
(define (generalize-scope sc)
  (if (representative-scope? sc)
      (shifted-multi-scope (representative-scope-phase sc)
                           (representative-scope-owner sc))
      sc))

(define (add-scope s sc)
  (apply-scope s (generalize-scope sc) set-add propagation-add))

(define (add-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (add-scope s sc)))

(define (remove-scope s sc)
  (apply-scope s (generalize-scope sc) set-remove propagation-remove))

(define (remove-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (remove-scope s sc)))

(define (set-flip s e)
  (if (set-member? s e)
      (set-remove s e)
      (set-add s e)))

(define (flip-scope s sc)
  (apply-scope s (generalize-scope sc) set-flip propagation-flip))

(define (flip-scopes s scs)
  (for/fold ([s s]) ([sc (in-list scs)])
    (flip-scope s sc)))

;; Pushes a multi-scope to accomodate multiple top-level namespaces.
;; See "fallback.rkt".
(define (push-scope s sms)
  (define-memo-lite (push smss/maybe-fallbacks)
    (define smss (fallback-first smss/maybe-fallbacks))
    (cond
     [(set-empty? smss) (set-add smss sms)]
     [(set-member? smss sms) smss/maybe-fallbacks]
     [else (fallback-push (set-add smss sms)
                          smss/maybe-fallbacks)]))
  (syntax-map s
              (lambda (tail? x) x)
              (lambda (s d)
                (struct-copy syntax s
                             [content d]
                             [shifted-multi-scopes
                              (push (syntax-shifted-multi-scopes s))]))
              syntax-e))

;; ----------------------------------------

(struct propagation (prev-scs scope-ops)
        #:property prop:propagation syntax-e)

(define (propagation-add prop sc prev-scs)
  (if prop
      (struct-copy propagation prop
                   [scope-ops (hash-set (propagation-scope-ops prop)
                                        sc
                                        'add)])
      (propagation prev-scs (hasheq sc 'add))))

(define (propagation-remove prop sc prev-scs)
  (if prop
      (struct-copy propagation prop
                   [scope-ops (hash-set (propagation-scope-ops prop)
                                        sc
                                        'remove)])
      (propagation prev-scs (hasheq sc 'remove))))

(define (propagation-flip prop sc prev-scs)
  (if prop
      (let* ([ops (propagation-scope-ops prop)]
             [current-op (hash-ref ops sc #f)])
        (cond
         [(and (eq? current-op 'flip)
               (= 1 (hash-count ops)))
          ;; Nothing left to propagate
          #f]
         [else
          (struct-copy propagation prop
                       [scope-ops
                        (if (eq? current-op 'flip)
                            (hash-remove ops sc)
                            (hash-set ops sc (case current-op
                                               [(add) 'remove]
                                               [(remove) 'add]
                                               [else 'flip])))])]))
      (propagation prev-scs (hasheq sc 'flip))))

(define (propagation-apply prop scs parent-s)
  (cond
   [(not prop) scs]
   [(eq? (propagation-prev-scs prop) scs)
    (syntax-scopes parent-s)]
   [else
    (for/fold ([scs scs]) ([(sc op) (in-hash (propagation-scope-ops prop))])
      (case op
       [(add) (set-add scs sc)]
       [(remove) (set-remove scs sc)]
       [else (set-flip scs sc)]))]))

(define (propagation-merge prop base-prop prev-scs)
  (cond
   [(not prop) base-prop]
   [(not base-prop) (propagation prev-scs
                                 (propagation-scope-ops prop))]
   [else
    (define new-ops
      (for/fold ([ops (propagation-scope-ops base-prop)]) ([(sc op) (in-hash (propagation-scope-ops prop))])
        (case op
          [(add) (hash-set ops sc 'add)]
          [(remove) (hash-set ops sc 'remove)]
          [else ; flip
           (define current-op (hash-ref ops sc #f))
           (case current-op
             [(add) (hash-set ops sc 'remove)]
             [(remove) (hash-set ops sc 'add)]
             [(flip) (hash-remove ops sc)]
             [else (hash-set ops sc 'flip)])])))
    (if (zero? (hash-count new-ops))
        #f
        (propagation (propagation-prev-scs base-prop) new-ops))]))

;; ----------------------------------------

;; To shift a syntax's phase, we only have to shift the phase
;; of any phase-specific scopes. The bindings attached to a
;; scope must be represented in such a s way that the binding
;; shift is implicit via the phase in which the binding
;; is resolved.
(define (shift-multi-scope sms delta)
  (if (zero? delta)
      sms
      (shifted-multi-scope (phase+ delta (shifted-multi-scope-phase sms))
                           (shifted-multi-scope-multi-scope sms))))

;; Since we tend to shift rarely and only for whole modules, it's
;; probably not worth making this lazy
(define (syntax-shift-phase-level s phase)
  (if (eqv? phase 0)
      s
      (let ()
        (define-memo-lite (shift-all smss)
          (fallback-map
           smss
           (lambda (smss)
             (for/set ([sms (in-set smss)])
               (shift-multi-scope sms phase)))))
        (syntax-map s
                    (lambda (tail? d) d)
                    (lambda (s d)
                      (struct-copy syntax s
                                   [content d]
                                   [shifted-multi-scopes
                                    (shift-all (syntax-shifted-multi-scopes s))]))
                    syntax-e))))

;; ----------------------------------------

;; Scope swapping is used to make top-level compilation relative to
;; the top level. Each top-level environment has a set of scopes that
;; identify the environment; usually, it's a common outside-edge scope
;; and a namespace-specific inside-edge scope, but there can be
;; additional scopes due to `module->namespace` on a module that was
;; expanded multiple times (where each expansion adds scopes).
(define (syntax-swap-scopes s src-scopes dest-scopes)
  (if (equal? src-scopes dest-scopes)
      s
      (let-values ([(src-smss src-scs)
                    (set-partition (for/set ([sc (in-set src-scopes)])
                                     (generalize-scope sc))
                                   shifted-multi-scope?)]
                   [(dest-smss dest-scs)
                    (set-partition (for/set ([sc (in-set dest-scopes)])
                                     (generalize-scope sc))
                                   shifted-multi-scope?)])
        (define-memo-lite (swap-scs scs)
          (if (subset? src-scs scs)
              (set-union (set-subtract scs src-scs) dest-scs)
              scs))
        (define-memo-lite (swap-smss smss)
          (fallback-update-first
           smss
           (lambda (smss)
             (if (subset? src-smss smss)
                 (set-union (set-subtract smss src-smss) dest-smss)
                 smss))))
        (syntax-map s
                    (lambda (tail? d) d)
                    (lambda (s d)
                      (struct-copy syntax s
                                   [content d]
                                   [scopes (swap-scs (syntax-scopes s))]
                                   [shifted-multi-scopes
                                    (swap-smss (syntax-shifted-multi-scopes s))]))
                    syntax-e))))

;; ----------------------------------------

;; Assemble the complete set of scopes at a given phase by extracting
;; a phase-specific representative from each multi-scope.
(define (syntax-scope-set s phase)
  (scope-set-at-fallback s (fallback-first (syntax-shifted-multi-scopes s)) phase))
  
(define (scope-set-at-fallback s smss phase)
  (for/fold ([scopes (syntax-scopes s)]) ([sms (in-set smss)])
    (set-add scopes (multi-scope-to-scope-at-phase (shifted-multi-scope-multi-scope sms)
                                                   (phase- (shifted-multi-scope-phase sms)
                                                           phase)))))

(define (find-max-scope scopes)
  (when (set-empty? scopes)
    (error "cannot bind in empty scope set"))
  (for/fold ([max-sc (set-first scopes)]) ([sc (in-set scopes)])
    (if (scope>? sc max-sc)
        sc
        max-sc)))

(define (add-binding-in-scopes! scopes sym binding)
  (define max-sc (find-max-scope scopes))
  (define bindings (scope-bindings max-sc))
  (define sym-bindings (hash-ref bindings sym #hash()))
  (set-scope-bindings! max-sc (hash-set bindings
                                        sym
                                        (hash-set sym-bindings scopes binding))))

(define (add-binding! id binding phase)
  (add-binding-in-scopes! (syntax-scope-set id phase) (syntax-e id) binding))

(define (add-bulk-binding! s binding phase)
  (define scopes (syntax-scope-set s phase))
  (define max-sc (find-max-scope scopes))
  (set-scope-bulk-bindings! max-sc
                            (cons (bulk-binding-at scopes binding)
                                  (scope-bulk-bindings max-sc)))
  (remove-matching-bindings! max-sc scopes binding))

(define (syntax-any-macro-scopes? s)
  (for/or ([sc (in-set (syntax-scopes s))])
    (eq? (scope-kind sc) 'macro)))

;; ----------------------------------------

;; Result is #f for no binding, `ambigious-value` for an ambigious binding,
;; or binding value
(define (resolve s phase
                 #:ambiguous-value [ambiguous-value #f]
                 #:exactly? [exactly? #f]
                 ;; For resolving bulk bindings in `free-identifier=?` chains:
                 #:extra-shifts [extra-shifts null])
  (unless (identifier? s)
    (raise-argument-error 'resolve "identifier?" s))
  (unless (phase? phase)
    (raise-argument-error 'resolve "phase?" phase))
  (let fallback-loop ([smss (syntax-shifted-multi-scopes s)])
    (define scopes (scope-set-at-fallback s (fallback-first smss) phase))
    (define sym (syntax-e s))
    (define candidates
      (for*/list ([sc (in-set scopes)]
                  [bindings (in-value
                             (let ([bindings (or (hash-ref (scope-bindings sc) sym #f)
                                                 #hash())])
                               ;; Check bulk bindings; if a symbol match is found,
                               ;; synthesize a non-bulk binding table, as long as the
                               ;; same set of scopes is not already mapped
                               (for*/fold ([bindings bindings])
                                          ([bulk-at (in-list (scope-bulk-bindings sc))]
                                           [bulk (in-value (bulk-binding-at-bulk bulk-at))]
                                           [syms (in-value (bulk-binding-symbols bulk s extra-shifts))]
                                           [b-info (in-value (hash-ref syms sym #f))]
                                           #:when (and b-info
                                                       (not (hash-ref bindings (bulk-binding-at-scopes bulk-at) #f))))
                                 (hash-set bindings
                                           (bulk-binding-at-scopes bulk-at)
                                           ((bulk-binding-create bulk) bulk b-info sym)))))]
                  [(b-scopes binding) (in-hash bindings)]
                  #:when (subset? b-scopes scopes))
        (cons b-scopes binding)))
    (define max-candidate
      (and (pair? candidates)
           (for/fold ([max-c (car candidates)]) ([c (in-list (cdr candidates))])
             (if ((set-count (car c)) . > . (set-count (car max-c)))
                 c
                 max-c))))
    (cond
     [max-candidate
      (cond
       [(not (for/and ([c (in-list candidates)])
               (subset? (car c) (car max-candidate))))
        (if (fallback? smss)
            (fallback-loop (fallback-rest smss))
            ambiguous-value)]
       [else
        (and (or (not exactly?)
                 (equal? (set-count scopes)
                         (set-count (car max-candidate))))
             (cdr max-candidate))])]
     [else
      (if (fallback? smss)
          (fallback-loop (fallback-rest smss))
          #f)])))

;; ----------------------------------------

;; The bindings of `bulk at `scopes` should shadow any existing
;; mappings in `sym-bindings`
(define (remove-matching-bindings! sc scopes bulk)
  (define bulk-symbols (bulk-binding-symbols bulk #f null))
  (define bindings (scope-bindings sc))
  (define new-bindings
    (cond
     [((hash-count bindings) . < . (hash-count bulk-symbols))
      ;; Faster to consider each sym in `sym-binding`
      (for/fold ([bindings bindings]) ([(sym sym-bindings) (in-hash bindings)])
        (if (hash-ref bulk-symbols sym #f)
            (hash-set bindings sym (hash-remove sym-bindings scopes))
            bindings))]
     [else
      ;; Faster to consider each sym in `bulk-symbols`
      (for/fold ([bindings bindings]) ([sym (in-hash-keys bulk-symbols)])
        (define sym-bindings (hash-ref bindings sym #f))
        (if sym-bindings
            (hash-set bindings sym (hash-remove sym-bindings scopes))
            bindings))]))
  (set-scope-bindings! sc new-bindings))

;; ----------------------------------------

(define (bound-identifier=? a b phase)
  (and (eq? (syntax-e a)
            (syntax-e b))
       (equal? (syntax-scope-set a phase)
               (syntax-scope-set b phase))))

;; ----------------------------------------

(define (prune-bindings-to-reachable bindings state)
  (or (hash-ref (serialize-state-bindings-intern state) bindings #f)
      (let ([reachable-scopes (serialize-state-reachable-scopes state)])
        (define new-bindings
          (for*/hash ([(sym bindings-for-sym) (in-hash bindings)]
                      [new-bindings-for-sym
                       (in-value
                        (for/hash ([(scopes binding) (in-hash bindings-for-sym)]
                                   #:when (subset? scopes reachable-scopes))
                          (values (intern-scopes scopes state) binding)))]
                      #:unless (zero? (hash-count new-bindings-for-sym)))
            (values sym new-bindings-for-sym)))
        (hash-set! (serialize-state-bindings-intern state) bindings new-bindings)
        new-bindings)))

(define (prune-bulk-bindings-to-reachable bulk-bindings state)
  (and bulk-bindings
       (or (hash-ref (serialize-state-bulk-bindings-intern state) bulk-bindings #f)
           (let ([reachable-scopes (serialize-state-reachable-scopes state)])
             (define new-bulk-bindings
               (for/list ([bba (in-list bulk-bindings)]
                          #:when (subset? (bulk-binding-at-scopes bba) reachable-scopes))
                 (struct-copy bulk-binding-at bba
                              [scopes (intern-scopes (bulk-binding-at-scopes bba) state)])))
             (hash-set! (serialize-state-bulk-bindings-intern state) bulk-bindings new-bulk-bindings)
             (and (pair? new-bulk-bindings)
                  new-bulk-bindings)))))

(define (register-bindings-reachable bindings reachable-scopes reach register-trigger)
  (for* ([(sym bindings-for-sym) (in-hash bindings)]
         [(scopes binding) (in-hash bindings-for-sym)])
    (define v (and (binding-reach-scopes? binding)
                   ((binding-reach-scopes-ref binding) binding)))
    (when v
      (cond
       [(subset? scopes reachable-scopes)
        (reach v)]
       [else
        (for ([sc (in-set scopes)]
              #:unless (set-member? reachable-scopes sc))
          (register-trigger sc v))]))))