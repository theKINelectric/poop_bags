package subject

class Main {
    fun greet(name: String?): String {
        val who = name ?: "stranger"
        return if (who.length > 0) "hi $who" else "nobody"
    }
}
