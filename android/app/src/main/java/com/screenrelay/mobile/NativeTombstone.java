package com.screenrelay.mobile;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

final class NativeTombstone {
    private static final int MAX_INPUT_BYTES = 256 * 1024;
    private static final int MAX_OUTPUT_CHARS = 16 * 1024;
    private static final int MAX_FRAMES = 24;
    private static final int MAX_CAUSES = 4;

    private NativeTombstone() {}

    // This reads selected fields from AOSP debuggerd/proto/tombstone.proto, available since API 31.
    static String summarize(byte[] trace) {
        if (trace == null || trace.length == 0) {
            return "";
        }
        int end = Math.min(trace.length, MAX_INPUT_BYTES);
        Fields tombstone = new Fields(trace, 0, end);
        int crashingTid = 0;
        String signal = "";
        String abort = "";
        StringBuilder causes = new StringBuilder();
        int causeCount = 0;
        while (tombstone.next()) {
            if (tombstone.wire == 0 && tombstone.field == 6 && tombstone.value > 0
                    && tombstone.value <= Integer.MAX_VALUE) {
                crashingTid = (int) tombstone.value;
            } else if (tombstone.wire == 2) {
                switch (tombstone.field) {
                    case 10 -> signal = readSignal(tombstone.message());
                    case 14 -> abort = tombstone.text(1024);
                    case 15 -> {
                        if (causeCount < MAX_CAUSES && appendCause(causes, tombstone.message())) {
                            causeCount++;
                        }
                    }
                    default -> { }
                }
            }
        }

        StringBuilder summary = new StringBuilder();
        if (!signal.isEmpty()) {
            summary.append(signal).append('\n');
        }
        if (!abort.isEmpty()) {
            summary.append("终止消息 ").append(abort).append('\n');
        }
        summary.append(causes);
        if (crashingTid != 0) {
            summary.append("崩溃线程 TID ").append(crashingTid).append('\n');
            Fields thread = findThread(new Fields(trace, 0, end), crashingTid);
            if (thread != null) {
                appendBacktrace(summary, thread);
            }
        }
        // UTF-8 uses at most three bytes per UTF-16 code unit, including replacement characters.
        return summary.substring(0, Math.min(summary.length(), MAX_OUTPUT_CHARS));
    }

    private static String readSignal(Fields message) {
        Integer number = null;
        Integer code = null;
        String name = "";
        String codeName = "";
        while (message.next()) {
            if (message.wire == 0) {
                if (message.field == 1) {
                    number = (int) message.value;
                } else if (message.field == 3) {
                    code = (int) message.value;
                }
            } else if (message.wire == 2) {
                if (message.field == 2) {
                    name = message.text(128);
                } else if (message.field == 4) {
                    codeName = message.text(128);
                }
            }
        }

        StringBuilder signal = new StringBuilder();
        if (number != null || !name.isEmpty()) {
            signal.append("原生信号");
            appendSignalValue(signal, number, name);
        }
        if (code != null || !codeName.isEmpty()) {
            if (signal.length() != 0) {
                signal.append("，");
            }
            signal.append("信号码");
            appendSignalValue(signal, code, codeName);
        }
        return signal.toString();
    }

    private static void appendSignalValue(StringBuilder line, Integer number, String name) {
        if (number != null) {
            line.append(' ').append(number);
        }
        if (!name.isEmpty()) {
            line.append(" (").append(name).append(')');
        }
    }

    private static boolean appendCause(StringBuilder output, Fields message) {
        while (message.next()) {
            if (message.field == 1 && message.wire == 2) {
                String text = message.text(256);
                if (!text.isEmpty()) {
                    output.append("可能原因 ").append(text).append('\n');
                    return true;
                }
            }
        }
        return false;
    }

    private static Fields findThread(Fields tombstone, int crashingTid) {
        while (tombstone.next()) {
            if (tombstone.field != 16 || tombstone.wire != 2) {
                continue;
            }
            Fields entry = tombstone.message();
            long tid = 0;
            Fields thread = null;
            while (entry.next()) {
                if (entry.field == 1 && entry.wire == 0) {
                    tid = entry.value;
                } else if (entry.field == 2 && entry.wire == 2) {
                    thread = entry.message();
                }
            }
            if (tid == crashingTid && thread != null) {
                return thread;
            }
        }
        return null;
    }

    private static void appendBacktrace(StringBuilder output, Fields thread) {
        String name = "";
        StringBuilder frames = new StringBuilder();
        int frameCount = 0;
        while (thread.next()) {
            if (thread.wire != 2) {
                continue;
            }
            if (thread.field == 2) {
                name = thread.text(128);
            } else if (thread.field == 4 && frameCount < MAX_FRAMES
                    && appendFrame(frames, thread.message(), frameCount)) {
                frameCount++;
            }
        }
        if (!name.isEmpty()) {
            output.append("线程名 ").append(name).append('\n');
        }
        if (frames.length() != 0) {
            output.append("原生调用栈\n").append(frames);
        }
    }

    private static boolean appendFrame(StringBuilder output, Fields frame, int index) {
        long relativePc = 0;
        long functionOffset = 0;
        String function = "";
        String file = "";
        while (frame.next()) {
            if (frame.wire == 0) {
                if (frame.field == 1) {
                    relativePc = frame.value;
                } else if (frame.field == 5) {
                    functionOffset = frame.value;
                }
            } else if (frame.wire == 2) {
                if (frame.field == 4) {
                    function = frame.text(256);
                } else if (frame.field == 6) {
                    file = frame.text(256);
                }
            }
        }
        if (relativePc == 0 && function.isEmpty() && file.isEmpty()) {
            return false;
        }
        output.append(String.format(Locale.ROOT, "#%02d pc %016x", index, relativePc));
        if (!file.isEmpty()) {
            output.append(' ').append(file);
        }
        if (!function.isEmpty()) {
            output.append(" (").append(function);
            if (functionOffset != 0) {
                output.append('+').append(Long.toUnsignedString(functionOffset));
            }
            output.append(')');
        }
        output.append('\n');
        return true;
    }

    /** A bounded protobuf cursor. A truncated embedded message can still yield its complete prefix. */
    private static final class Fields {
        private final byte[] bytes;
        private final int end;
        private int position;
        private int payloadStart;
        private int payloadEnd;
        private int field;
        private int wire;
        private long value;

        Fields(byte[] bytes, int start, int end) {
            this.bytes = bytes;
            this.position = start;
            this.end = end;
        }

        boolean next() {
            if (!readVarint() || value < 8 || value > 0xffffffffL) {
                return false;
            }
            field = (int) (value >>> 3);
            wire = (int) (value & 7);
            switch (wire) {
                case 0 -> { return readVarint(); }
                case 1, 5 -> {
                    int size = wire == 1 ? 8 : 4;
                    if (size > end - position) {
                        return false;
                    }
                    position += size;
                    return true;
                }
                case 2 -> {
                    if (!readVarint() || value < 0) {
                        return false;
                    }
                    payloadStart = position;
                    position += (int) Math.min(value, end - position);
                    payloadEnd = position;
                    return true;
                }
                default -> { return false; }
            }
        }

        private boolean readVarint() {
            value = 0;
            for (int shift = 0; shift <= 63 && position < end; shift += 7) {
                int next = bytes[position++] & 0xff;
                if (shift == 63 && next > 1) {
                    return false;
                }
                value |= (long) (next & 0x7f) << shift;
                if ((next & 0x80) == 0) {
                    return true;
                }
            }
            return false;
        }

        Fields message() {
            return new Fields(bytes, payloadStart, payloadEnd);
        }

        String text(int limit) {
            int count = Math.min(limit, payloadEnd - payloadStart);
            String decoded = new String(bytes, payloadStart, count, StandardCharsets.UTF_8);
            StringBuilder line = new StringBuilder(decoded.length());
            for (int i = 0; i < decoded.length(); i++) {
                char c = decoded.charAt(i);
                line.append(Character.isISOControl(c) || c == '\u2028' || c == '\u2029' ? ' ' : c);
            }
            return line.toString().trim();
        }
    }
}
