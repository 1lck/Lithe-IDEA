#import <Foundation/Foundation.h>
#include <vector>

namespace demo {
template <typename T>
class Box {
public:
    explicit Box(T value) : value_(value) {}
    T get() const { return value_; }
private:
    T value_;
};
}

// A comment
@implementation Wrapper
- (void)run {
    std::vector<int> items{1, 2, 0x1F};
    auto box = demo::Box<int>(items.size());
    NSLog(@"Items: %zu", static_cast<size_t>(box.get()));
}
@end
