package demo.app

import kotlin.math.max

/** Documentation. */
@JvmInline
value class Id(val raw: Long)

data class User(val name: String, var age: Int = 0) : Base(), Comparable<User> {
    override fun compareTo(other: User): Int = age - other.age

    fun greet(): String {
        // comment
        val list = listOf(1, 2, 0x1F, 3.5f)
        return "Hi $name, ${list.size} items\n"
    }
}

suspend fun main() {
    val user = User("Ann") ?: return
    when (user.age) {
        in 0..17 -> println("minor")
        else -> println('x')
    }
}
