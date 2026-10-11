/// A stack of values.
pub struct Stack<T> {
    items: Vec<T>,
}

// The methods of the stack.
// Each method keeps the order of the items.
impl<T: Clone> Stack<T> {
    /// Makes an empty stack.
    pub fn new() -> Self {
        Stack { items: Vec::new() }
    }

    /// Adds `item` on top.
    pub fn push(&mut self, item: T) {
        self.items.push(item);
    }

    pub fn peek(&self) -> Option<&T>
    where
        T: Clone,
    {
        fn first<U>(values: &[U]) -> Option<&U> {
            values.first()
        }
        first(&self.items)
    }

    const LIMIT: usize = 64;
}
