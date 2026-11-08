/*
 * A block comment that spans
 * several lines.
 */
package org.example.sample;

import java.util.*;
import java.util.function.Function;
import static java.lang.Math.max;

/**
 * Javadoc with {@link Map} and a tag.
 *
 * @param <T> the element type
 * @author someone
 */
@SuppressWarnings({"unchecked", "rawtypes"})
public final class Sample<T extends Comparable<? super T>> implements Iterable<T>, AutoCloseable {
    private static final long SERIAL = 0x1F_FFL;
    protected volatile int count = 1_000;
    private final double ratio = 3.14e-2d, other = .5f;
    private final char tab = '\t', quote = '\'', unicode = 'é';
    private final String text = "line\nnext \"quoted\" \\ end";
    private final List<Map<String, int[]>> nested = new ArrayList<>();
    private String 名字 = "中文字符串";

    enum Color { RED, GREEN("g"), BLUE; Color() {} Color(String s) {} }

    record Point(int x, int y) {
        Point {
            if (x < 0) throw new IllegalArgumentException("x");
        }
    }

    sealed interface Shape permits Circle, Square {}
    record Circle(double r) implements Shape {}
    record Square(double side) implements Shape {}

    @Override
    public Iterator<T> iterator() {
        return Collections.<T>emptyList().iterator();
    }

    public static <K, V extends Number> Map<K, V> build(K key, V value) throws Exception {
        var map = new HashMap<K, V>();
        map.put(key, value); // trailing comment
        return map;
    }

    int area(Shape shape) {
        return switch (shape) {
            case Circle c when c.r() > 10 -> (int) (Math.PI * c.r() * c.r());
            case Circle c -> 1;
            case Square s -> (int) (s.side() * s.side());
        };
    }

    void lambdas() {
        Function<Integer, Integer> twice = x -> x * 2;
        Runnable r = () -> { System.out.println("run"); };
        List.of(1, 2, 3).stream().map(String::valueOf).filter(s -> !s.isEmpty()).toList();
        int[] values = {1, 2, 3};
        for (int i = 0, j = values.length - 1; i < j; i++, j--) {
            values[i] ^= values[j] >>> 1;
            label:
            while (true) { break label; }
        }
        boolean flag = values.length >= 3 && !(values[0] != 1 || values[1] == 2) ? true : false;
        Object o = null;
        if (o instanceof String str && !str.isBlank()) {
            System.out.printf("%s%n", str);
        }
        String block = """
            Text block with "quotes" and \
            an escaped line break \t tab
            """;
        synchronized (this) {
            try (var in = new java.io.ByteArrayInputStream(new byte[0])) {
                assert in.available() == 0 : "empty";
            } catch (java.io.IOException | RuntimeException e) {
                throw new IllegalStateException(e);
            } finally {
                count--;
            }
        }
        new Thread() {
            @Override public void run() { super.run(); this.hashCode(); }
        }.start();
    }

    @Deprecated(since = "1.0", forRemoval = true)
    native void legacy(final int @Annotated [] array, String... rest);

    @Override
    public void close() {}
}
