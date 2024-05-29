(define (inc [x : Integer]) : Integer
    (+ x 1))
(define (map [v : (Vector Integer Integer)]) : Integer
    (+ (inc (vector-ref v 1)) (inc (vector-ref v 0)))) 
(map (vector 42 0))