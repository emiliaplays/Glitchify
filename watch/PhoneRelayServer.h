#import <Foundation/Foundation.h>
#include "PhonePCMCore.h"
bool GRStartServer(void);
void GRObserve(GPFormat format, const GPBuffer *buffers, uint32_t frames);
void GRPause(void);
NSDictionary *GRStatus(void);
