<?php
final class Store {
    private array $values = [];
    public function add(string $value): void { $this->values[] = $value; }
    public function values(): array { return $this->values; }
}
