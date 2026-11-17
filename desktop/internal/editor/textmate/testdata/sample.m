#import <Foundation/Foundation.h>
#import "Model.h"

// A comment
@interface Person : NSObject <NSCopying>
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger age;
- (instancetype)initWithName:(NSString *)name;
+ (void)greet;
@end

@implementation Person
- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self != nil && name.length > 0) {
        _name = [name copy];
        _age = 0x1F;
    }
    NSLog(@"Hello, %@! %d\n", name, 42);
    return self;
}
@end
