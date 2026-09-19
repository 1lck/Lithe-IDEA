import { BasicChannel } from '@theia/core/lib/common/message-rpc/channel';
import { Uint8ArrayReadBuffer, Uint8ArrayWriteBuffer } from '@theia/core/lib/common/message-rpc/uint8-array-message-buffer';

/**
 * Connects Theia's plugin side and Lithe's main side inside one process.
 *
 * Delivery is deferred to a later macrotask so that neither side re-enters the
 * other while it is still processing a message, matching the ordering Theia
 * gets from a real IPC channel.
 */
export function createInMemoryChannelPair(): [BasicChannel, BasicChannel] {
    let left: BasicChannel | undefined;
    let right: BasicChannel | undefined;
    const writerTo = (target: () => BasicChannel | undefined) => () => {
        const writer = new Uint8ArrayWriteBuffer();
        writer.onCommit(buffer => setImmediate(() => target()?.onMessageEmitter.fire(() => new Uint8ArrayReadBuffer(buffer))));
        return writer;
    };
    left = new BasicChannel(writerTo(() => right));
    right = new BasicChannel(writerTo(() => left));
    return [left, right];
}
