import Testing

@testable import FoundationModelsCodeContext

/// Tests for `ClassInheritance`: reading the base classes from a Python class
/// header, and the C3 method resolution order.
struct ClassInheritanceTests {
    @Test
    func readsTheBasesOfAPythonClassHeaderInOrder() {
        let names = ClassInheritance.baseNames(ofClassText: "class D(B, mixins.M, metaclass=Meta):\n    pass\n", filePath: "forms.py")

        #expect(names == ["B", "mixins.M"])
    }

    @Test
    func readsABaseListThatSpansLinesAfterDecorators() {
        let text = "@decorator(arg=1)\nclass D(\n    B,\n    Generic[T],\n    *extra,\n):\n    pass\n"

        let names = ClassInheritance.baseNames(ofClassText: text, filePath: "forms.py")

        #expect(names == ["B", "Generic"])
    }

    @Test
    func readsTheBasesAfterATypeParameterList() {
        let names = ClassInheritance.baseNames(ofClassText: "class Box[T](Base):\n    pass\n", filePath: "box.py")

        #expect(names == ["Base"])
    }

    @Test
    func aClassWithNoBaseListOrAnotherLanguageHasNoBases() {
        #expect(ClassInheritance.baseNames(ofClassText: "class A:\n    pass\n", filePath: "a.py").isEmpty)
        #expect(ClassInheritance.baseNames(ofClassText: "class A(B) {}\n", filePath: "A.swift").isEmpty)
    }

    @Test
    func methodResolutionOrderOfADiamondIsC3() {
        let bases = ["D": ["B", "M"], "B": ["A"], "M": ["A"], "A": []]

        let order = ClassInheritance.methodResolutionOrder(of: "D") { bases[$0] ?? [] }

        #expect(order == ["D", "B", "M", "A"])
    }

    @Test
    func methodResolutionOrderEndsOnACycle() {
        let bases = ["A": ["B"], "B": ["A"]]

        let order = ClassInheritance.methodResolutionOrder(of: "A") { bases[$0] ?? [] }

        #expect(order == ["A", "B"])
    }
}
