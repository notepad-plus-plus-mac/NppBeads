// BdDataSource — implements BeadsDataSource over BdCommandRunner.
// Pass-through layer: translates protocol calls into `bd` invocations
// and maps BdErrorKind → BeadsDataSourceErrorCode with userInfo.

#import <Foundation/Foundation.h>
#import "BeadsDataSource.h"

@class BdCommandRunner;

NS_ASSUME_NONNULL_BEGIN

@interface BdDataSource : NSObject <BeadsDataSource>

@property (nonatomic, strong, readonly) BdCommandRunner *runner;

- (instancetype)initWithRunner:(BdCommandRunner *)runner NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
