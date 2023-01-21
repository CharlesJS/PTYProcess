//
//  Watcher.swift
//
//  Created by Charles Srstka on 1/3/23.
//

import CSErrors
import Dispatch

extension PTYProcess {
    internal actor Watcher {
        let processIdentifier: pid_t

        private var _status: PTYProcess.Status
        var status: PTYProcess.Status {
            if case .suspended = self._status {
                // macOS doesn't send SIGCHLD signal when child receives SIGCONT, so we won't get automatically updated.
                // Thus, we check it manually if the process is stopped.

                self.refreshStatus(wait: false)
            }

            return self._status
        }

        var result: Result<PTYProcess.Status, Error>? = nil

        private var continuations: [CheckedContinuation<PTYProcess.Status, Error>] = []

        init(processIdentifier: pid_t) {
            self.processIdentifier = processIdentifier
            self._status = .running(processIdentifier)
        }

        func addContinuation(_ continuation: CheckedContinuation<PTYProcess.Status, Error>) {
            if let result = self.result {
                continuation.resume(with: result)
            } else {
                self.continuations.append(continuation)
            }
        }

        private var signalSource: DispatchSourceSignal? = nil
        func startWatching() async {
            let signalSource = DispatchSource.makeSignalSource(signal: SIGCHLD)
            self.signalSource = signalSource

            signalSource.setEventHandler {
                Task(priority: .userInitiated) {
                    self.refreshStatus(wait: true)
                }
            }

            signalSource.activate()

            return await withCheckedContinuation { continuation in
                signalSource.setRegistrationHandler {
                    continuation.resume()
                }
            }
        }

        func suspend() throws {
            try self.sendSignal(SIGSTOP)
        }

        func resume() throws {
            try self.sendSignal(SIGCONT)
        }

        func sendSignal(_ signal: Int32) throws {
            if kill(self.processIdentifier, signal) != 0 { throw errno() }
        }

        private func refreshStatus(wait: Bool) {
            var status = siginfo_t()

            var opts = WEXITED | WSTOPPED | WCONTINUED

            if !wait {
                opts |= WNOHANG | WNOWAIT
            }

            if waitid(P_PID, id_t(bitPattern: self.processIdentifier), &status, opts) < 0 {
                self.notify(result: .failure(errno()))
                return
            }

            if status.si_signo == 0 {
                return
            }

            guard status.si_signo == SIGCHLD, status.si_pid == self.processIdentifier else {
                print("Warning: Unexpected signal \(status)")
                return
            }

            switch status.si_code {
            case CLD_EXITED:
                self.setStatus(.exited(status.si_status), final: true)
            case CLD_KILLED, CLD_DUMPED:
                self.setStatus(.uncaughtSignal(status.si_status), final: true)
            case CLD_STOPPED:
                self.setStatus(.suspended(self.processIdentifier), final: false)
            case CLD_CONTINUED:
                self.setStatus(.running(self.processIdentifier), final: false)
            default: break
            }
        }

        private func setStatus(_ status: PTYProcess.Status, final: Bool) {
            self._status = status

            if final {
                self.signalSource?.setEventHandler(handler: nil)
                self.signalSource?.cancel()
                self.signalSource = nil

                self.notify(result: .success(status))
            }
        }

        private func notify(result: Result<PTYProcess.Status, Error>) {
            self.result = result

            for eachContinuation in self.continuations {
                eachContinuation.resume(with: result)
            }

            self.continuations.removeAll()
        }
    }
}
