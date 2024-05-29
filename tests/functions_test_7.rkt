(define (map [f : Integer] [v : (Vector Integer Integer)]) : Integer
    (+ (+ f (vector-ref v 1)) (+ f (vector-ref v 0)))) 
(define (inc [x : Integer]) : Integer
    (+ x 1))
(map 5 (vector 42 0))