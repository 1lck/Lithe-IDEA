<?php
require_once __DIR__ . '/../src/Store.php';
final class StoreTest extends \PHPUnit\Framework\TestCase {
    public function testKeepsInsertionOrder(): void {
        $store = new Store(); $store->add('a'); $store->add('b');
        self::assertSame(['a', 'b'], $store->values());
    }
    public function testKeepsInsertionOrderWithDuplicates(): void {
        $store = new Store(); $store->add('a'); $store->add('a');
        self::assertSame(['a', 'a'], $store->values());
    }
}
