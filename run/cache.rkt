#lang racket/base
(require racket/file
         file/sha1)

(provide make-cache
         get-cached-compiled
         cache-compiled!)

(struct cache (dir 
               [table #:mutable] ; filename -> key [used for a cache file]
               in-memory))       ; key -> code     [when no cache filed is in use]

(define (cache-dir->file cache-dir)
  (build-path cache-dir "cache.rktd"))

(define (make-cache cache-dir)
  (define cache-file (and cache-dir
                          (cache-dir->file cache-dir)))
  (define table
    (if (and cache-file
             (file-exists? cache-file))
        (call-with-input-file* cache-file read)
        #hash()))
  (cache cache-dir table (make-hash)))

(define (get-cached-compiled cache path [notify-success void])
  (define cached-filename (hash-ref (cache-table cache)
                                    (path->string path)
                                    #f))
  (define cached-file (and cached-filename
                           (cache-dir cache)
                           (build-path (cache-dir cache)
                                       cached-filename)))
  (cond
   [(and cached-file
         (file-exists? cached-file))
    (notify-success)
    (parameterize ([read-accept-compiled #t])
      (call-with-input-file* cached-file read))]
   [(hash-ref (cache-in-memory cache) cached-filename #f)
    => (lambda (c)
         (notify-success)
         c)]
   [else #f]))

(define (cache-compiled! cache path c)
  (define file-name (sha1 (open-input-bytes (path->bytes path))))
  (define new-table (hash-set (cache-table cache) (path->string path) file-name))
  (set-cache-table! cache new-table)
  (cond
   [(cache-dir cache)
    (define cache-file (cache-dir->file (cache-dir cache)))
    (make-directory* (cache-dir cache))
    (call-with-output-file*
     #:exists 'truncate
     (build-path (cache-dir cache) file-name)
     (lambda (o) (write c o)))
    (call-with-output-file*
     #:exists 'truncate
     cache-file
     (lambda (o) (writeln new-table o)))]
   [else
    (hash-set! (cache-in-memory cache) file-name c)]))