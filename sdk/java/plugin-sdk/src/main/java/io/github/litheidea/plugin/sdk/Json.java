package io.github.litheidea.plugin.sdk;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Minimal JSON reader and writer for protocol messages and stored state.
 *
 * <p>The SDK carries its own codec so that a plugin can shade it next to any
 * JSON library without version conflicts. Values map to plain Java types:
 * objects to {@code Map<String, Object>} (insertion-ordered), arrays to
 * {@code List<Object>}, strings to {@code String}, booleans to
 * {@code Boolean}, {@code null} to {@code null}, integers to {@code Long} (or
 * {@code BigInteger} beyond its range), and other numbers to {@code Double}.
 */
public final class Json {
    /** Deeper input is refused instead of overflowing the reader's stack. */
    private static final int MAX_DEPTH = 512;

    private Json() {}

    /** A value that is not JSON, or one JSON cannot represent. */
    public static final class JsonException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public JsonException(String message) {
            super(message);
        }
    }

    /** Parses one JSON document; trailing content other than whitespace is an error. */
    public static Object parse(String text) {
        Reader reader = new Reader(text);
        reader.skipWhitespace();
        Object value = reader.value(0);
        reader.skipWhitespace();
        if (reader.position != text.length()) {
            throw reader.error("Unexpected content after the value");
        }
        return value;
    }

    /**
     * Encodes {@code value}. Maps need string keys; numbers must be finite.
     * Arrays of objects and any {@link Collection} encode as JSON arrays.
     */
    public static String stringify(Object value) {
        StringBuilder output = new StringBuilder();
        write(output, value, 0);
        return output.toString();
    }

    /** {@code value} as an object, or an empty map when it is {@code null}. */
    @SuppressWarnings("unchecked")
    public static Map<String, Object> object(Object value) {
        if (value == null) {
            return new LinkedHashMap<>();
        }
        if (value instanceof Map) {
            return (Map<String, Object>) value;
        }
        throw new JsonException("Expected a JSON object.");
    }

    /** The string at {@code key}, or {@code null} when it is missing or not a string. */
    public static String string(Map<String, ?> object, String key) {
        Object value = object.get(key);
        return value instanceof String ? (String) value : null;
    }

    private static void write(StringBuilder output, Object value, int depth) {
        if (depth > MAX_DEPTH) {
            throw new JsonException("The value is nested too deeply, or contains itself.");
        }
        if (value == null) {
            output.append("null");
        } else if (value instanceof String || value instanceof Character) {
            quote(output, value.toString());
        } else if (value instanceof Boolean) {
            output.append(value.toString());
        } else if (value instanceof Double || value instanceof Float) {
            output.append(decimal(((Number) value).doubleValue()));
        } else if (value instanceof Long || value instanceof Integer || value instanceof Short
                || value instanceof Byte || value instanceof BigInteger) {
            output.append(value.toString());
        } else if (value instanceof BigDecimal) {
            output.append(((BigDecimal) value).toString());
        } else if (value instanceof Map) {
            output.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
                if (!(entry.getKey() instanceof String)) {
                    throw new JsonException("Object keys must be strings.");
                }
                if (!first) {
                    output.append(',');
                }
                first = false;
                quote(output, (String) entry.getKey());
                output.append(':');
                write(output, entry.getValue(), depth + 1);
            }
            output.append('}');
        } else if (value instanceof Collection) {
            writeArray(output, ((Collection<?>) value).toArray(), depth);
        } else if (value instanceof Object[]) {
            writeArray(output, (Object[]) value, depth);
        } else {
            throw new JsonException("A " + value.getClass().getName() + " is not a JSON value.");
        }
    }

    private static void writeArray(StringBuilder output, Object[] values, int depth) {
        output.append('[');
        for (int index = 0; index < values.length; index++) {
            if (index > 0) {
                output.append(',');
            }
            write(output, values[index], depth + 1);
        }
        output.append(']');
    }

    private static String decimal(double value) {
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            throw new JsonException("JSON has no representation for " + value + ".");
        }
        // Integral values print without a fraction, as JavaScript prints them.
        if (value == Math.rint(value) && Math.abs(value) < 1e15) {
            return Long.toString((long) value);
        }
        return Double.toString(value);
    }

    private static void quote(StringBuilder output, String text) {
        output.append('"');
        for (int index = 0; index < text.length(); index++) {
            char character = text.charAt(index);
            switch (character) {
                case '"':
                    output.append("\\\"");
                    break;
                case '\\':
                    output.append("\\\\");
                    break;
                case '\n':
                    output.append("\\n");
                    break;
                case '\r':
                    output.append("\\r");
                    break;
                case '\t':
                    output.append("\\t");
                    break;
                case '\b':
                    output.append("\\b");
                    break;
                case '\f':
                    output.append("\\f");
                    break;
                default:
                    if (character < 0x20 || isLoneSurrogate(text, index)) {
                        // A lone surrogate has no UTF-8 encoding; escaping it
                        // keeps the frame valid, as JSON.stringify does.
                        output.append(String.format("\\u%04x", (int) character));
                    } else {
                        output.append(character);
                    }
            }
        }
        output.append('"');
    }

    private static boolean isLoneSurrogate(String text, int index) {
        char character = text.charAt(index);
        if (Character.isHighSurrogate(character)) {
            return index + 1 >= text.length() || !Character.isLowSurrogate(text.charAt(index + 1));
        }
        if (Character.isLowSurrogate(character)) {
            return index == 0 || !Character.isHighSurrogate(text.charAt(index - 1));
        }
        return false;
    }

    private static final class Reader {
        private final String text;
        private int position;

        Reader(String text) {
            this.text = text;
        }

        Object value(int depth) {
            if (depth > MAX_DEPTH) {
                throw error("The document is nested too deeply");
            }
            if (position >= text.length()) {
                throw error("Unexpected end of input");
            }
            char character = text.charAt(position);
            switch (character) {
                case '{':
                    return object(depth);
                case '[':
                    return array(depth);
                case '"':
                    return string();
                case 't':
                    return literal("true", Boolean.TRUE);
                case 'f':
                    return literal("false", Boolean.FALSE);
                case 'n':
                    return literal("null", null);
                default:
                    if (character == '-' || (character >= '0' && character <= '9')) {
                        return number();
                    }
                    throw error("Unexpected character");
            }
        }

        private Map<String, Object> object(int depth) {
            Map<String, Object> result = new LinkedHashMap<>();
            position++;
            skipWhitespace();
            if (peek() == '}') {
                position++;
                return result;
            }
            for (;;) {
                skipWhitespace();
                if (peek() != '"') {
                    throw error("Expected a property name");
                }
                String key = string();
                skipWhitespace();
                expect(':');
                skipWhitespace();
                result.put(key, value(depth + 1));
                skipWhitespace();
                char next = peek();
                position++;
                if (next == '}') {
                    return result;
                }
                if (next != ',') {
                    throw error("Expected ',' or '}'");
                }
            }
        }

        private List<Object> array(int depth) {
            List<Object> result = new ArrayList<>();
            position++;
            skipWhitespace();
            if (peek() == ']') {
                position++;
                return result;
            }
            for (;;) {
                skipWhitespace();
                result.add(value(depth + 1));
                skipWhitespace();
                char next = peek();
                position++;
                if (next == ']') {
                    return result;
                }
                if (next != ',') {
                    throw error("Expected ',' or ']'");
                }
            }
        }

        private String string() {
            position++;
            StringBuilder result = new StringBuilder();
            for (;;) {
                if (position >= text.length()) {
                    throw error("Unterminated string");
                }
                char character = text.charAt(position++);
                if (character == '"') {
                    return result.toString();
                }
                if (character < 0x20) {
                    throw error("Control character in string");
                }
                if (character != '\\') {
                    result.append(character);
                    continue;
                }
                if (position >= text.length()) {
                    throw error("Unterminated escape");
                }
                char escape = text.charAt(position++);
                switch (escape) {
                    case '"':
                    case '\\':
                    case '/':
                        result.append(escape);
                        break;
                    case 'b':
                        result.append('\b');
                        break;
                    case 'f':
                        result.append('\f');
                        break;
                    case 'n':
                        result.append('\n');
                        break;
                    case 'r':
                        result.append('\r');
                        break;
                    case 't':
                        result.append('\t');
                        break;
                    case 'u':
                        if (position + 4 > text.length()) {
                            throw error("Incomplete unicode escape");
                        }
                        int code = 0;
                        for (int index = 0; index < 4; index++) {
                            int digit = Character.digit(text.charAt(position++), 16);
                            if (digit < 0) {
                                throw error("Invalid unicode escape");
                            }
                            code = code * 16 + digit;
                        }
                        result.append((char) code);
                        break;
                    default:
                        throw error("Invalid escape");
                }
            }
        }

        private Object number() {
            int start = position;
            if (peek() == '-') {
                position++;
            }
            if (peek() == '0') {
                position++;
            } else if (isDigit(peek())) {
                digits();
            } else {
                throw error("Invalid number");
            }
            boolean integral = true;
            if (peek() == '.') {
                integral = false;
                position++;
                if (!isDigit(peek())) {
                    throw error("Invalid number");
                }
                digits();
            }
            if (peek() == 'e' || peek() == 'E') {
                integral = false;
                position++;
                if (peek() == '+' || peek() == '-') {
                    position++;
                }
                if (!isDigit(peek())) {
                    throw error("Invalid number");
                }
                digits();
            }
            String literal = text.substring(start, position);
            if (integral) {
                BigInteger value = new BigInteger(literal);
                return value.bitLength() < 64 ? (Object) value.longValue() : value;
            }
            return Double.parseDouble(literal);
        }

        private void digits() {
            while (isDigit(peek())) {
                position++;
            }
        }

        private Object literal(String word, Object value) {
            if (!text.startsWith(word, position)) {
                throw error("Unexpected literal");
            }
            position += word.length();
            return value;
        }

        private void expect(char character) {
            if (peek() != character) {
                throw error("Expected '" + character + "'");
            }
            position++;
        }

        private char peek() {
            return position < text.length() ? text.charAt(position) : '\0';
        }

        void skipWhitespace() {
            while (position < text.length()) {
                char character = text.charAt(position);
                if (character != ' ' && character != '\t' && character != '\n' && character != '\r') {
                    return;
                }
                position++;
            }
        }

        JsonException error(String message) {
            return new JsonException(message + " at offset " + position + ".");
        }

        private static boolean isDigit(char character) {
            return character >= '0' && character <= '9';
        }
    }
}
