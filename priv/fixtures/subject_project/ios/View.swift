struct Painter {
    func tint(_ x: Int) -> String {
        switch x {
        case 1:
            return "one"
        default:
            return "many"
        }
    }
}
