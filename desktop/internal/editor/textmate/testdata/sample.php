<!DOCTYPE html>
<html lang="en">
<!-- An HTML comment -->
<body class="main">
<?php
declare(strict_types=1);

namespace App\Models;

/** Documentation. */
final class User extends Model implements JsonSerializable
{
    private const LIMIT = 0x10;

    public function __construct(private string $name = "anon") {}

    public function greet(?int $times = 1): string
    {
        // a comment
        $items = array_map(fn($x) => $x * 2, [1, 2.5, 3]);
        return "Hello {$this->name}, " . count($items) . ' times' . PHP_EOL;
    }
}
?>
<p title="<?= htmlspecialchars($title) ?>">&amp; <?php echo $body; ?></p>
<script>const n = 1;</script>
<style>p { color: red; }</style>
</body>
</html>
