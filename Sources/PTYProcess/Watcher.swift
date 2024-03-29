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
                Task {
                    self.refreshStatus(wait: true)
                }
            }

            return await withCheckedContinuation { continuation in
                signalSource.setRegistrationHandler {
                    continuation.resume()
                }

                signalSource.activate()
            }
        }

        private func stopWatching() async {
            if let signalSource = self.signalSource {
                await withCheckedContinuation { continuation in
                    signalSource.setCancelHandler {
                        continuation.resume()
                    }

                    signalSource.cancel()
                }

                self.signalSource = nil
            }
        }

        func suspend() throws {
            try self.sendSignal(SIGSTOP)
        }

        func resume() throws {
            try self.sendSignal(SIGCONT)
        }

        func sendSignal(_ signal: Int32) throws {
            try callPOSIXFunction(expect: .zero) { kill(self.processIdentifier, signal) }
        }

        private func refreshStatus(wait: Bool) {
            var opts = WEXITED | WSTOPPED | WCONTINUED

            if !wait {
                opts |= WNOHANG | WNOWAIT
            }

            let sigInfo: siginfo_t
            do {
                sigInfo = try callPOSIXFunction(expect: .nonNegative) {
                    waitid(P_PID, id_t(bitPattern: self.processIdentifier), $0, opts)
                }
            } catch {
                self.notify(result: .failure(error))
                return
            }

            guard sigInfo.si_signo == SIGCHLD, sigInfo.si_pid == processIdentifier else {
                return
            }

            if let status = PTYProcess.Status(signalInfo: sigInfo) {
                switch status {
                case .exited, .uncaughtSignal:
                    self.setStatus(status, final: true)
                default:
                    self.setStatus(status, final: false)
                }
            }
        }

        private func setStatus(_ status: PTYProcess.Status, final: Bool) {
            self._status = status

            if final {
                Task {
                    await self.stopWatching()
                    self.notify(result: .success(status))
                }
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
