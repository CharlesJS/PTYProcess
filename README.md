# PTYProcess

A replacement for `Process`/`NSTask` that can automatically wrap standard output, standard error, or both in a pseudo-TTY.

Lets you use Swift Concurrency to wait for processes to exit without blocking a thread. Does not require Foundation.
