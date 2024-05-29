(define (maping [f : Integer] [v : (Vector Integer Integer)]) : Integer
    (+ (+ f (vector-ref v 1)) (+ f (vector-ref v 0)))) 
(define (inc [x : Integer]) : Integer
    (+ x 1))
(maping 5 (vector 41 1))