import { ChildProcess } from 'child_process';

/**
 * Records every child process started in this host so shutdown can end the ones
 * extensions failed to stop (for example a language server still importing a
 * project when its client asked it to exit).
 *
 * `spawn`, `fork`, `exec` and `execFile` all create a `ChildProcess` and call its
 * `spawn` method, so wrapping that single method sees every child regardless of
 * which module-level function an extension used.
 *
 * Only direct children are visible here. Lithe additionally starts the host in
 * its own process group (POSIX) or job object (Windows) and ends that whole tree,
 * which also covers grandchildren and a crashed host.
 */
export class ChildProcessTracker {
    private readonly children = new Set<ChildProcess>();

    install(): void {
        const tracker = this;
        // `ChildProcess.prototype.spawn` is internal to Node and absent from its type declarations.
        const prototype = ChildProcess.prototype as unknown as { spawn: (this: ChildProcess, ...args: unknown[]) => unknown };
        const originalSpawn = prototype.spawn;
        prototype.spawn = function (this: ChildProcess, ...args: unknown[]) {
            const result = originalSpawn.apply(this, args);
            tracker.track(this);
            return result;
        };
    }

    /**
     * Terminates children that are still running: SIGTERM first, SIGKILL for any
     * that outlive `graceMilliseconds`. Resolves once all have exited or the
     * SIGKILL wait of the same length has passed. Returns the number terminated.
     */
    async terminateAll(graceMilliseconds: number): Promise<number> {
        const running = [...this.children].filter(isRunning);
        if (running.length === 0) {
            return 0;
        }
        for (const child of running) {
            child.kill('SIGTERM');
        }
        const survivors = await this.waitForExit(running, graceMilliseconds);
        for (const child of survivors) {
            child.kill('SIGKILL');
        }
        await this.waitForExit(survivors, graceMilliseconds);
        return running.length;
    }

    private track(child: ChildProcess): void {
        if (child.pid === undefined) {
            return;
        }
        this.children.add(child);
        child.once('exit', () => this.children.delete(child));
    }

    /** Returns the children still running after at most `milliseconds`. */
    private async waitForExit(children: ChildProcess[], milliseconds: number): Promise<ChildProcess[]> {
        let timer: ReturnType<typeof setTimeout> | undefined;
        const deadline = new Promise<void>(resolve => {
            timer = setTimeout(resolve, milliseconds);
        });
        const exits = Promise.all(children.map(child => isRunning(child)
            ? new Promise<void>(resolve => child.once('exit', () => resolve()))
            : Promise.resolve()));
        await Promise.race([exits, deadline]);
        clearTimeout(timer);
        return children.filter(isRunning);
    }
}

function isRunning(child: ChildProcess): boolean {
    return child.exitCode === null && child.signalCode === null;
}
