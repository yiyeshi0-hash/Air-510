//
//  AnnouncementItem.m
//  Amethyst
//

#import "AnnouncementItem.h"

@implementation AnnouncementItem

+ (instancetype)itemFromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    AnnouncementItem *item = [[AnnouncementItem alloc] init];
    item.announcementId = dict[@"id"] ?: @"";
    item.title = dict[@"title"] ?: @"";
    item.date = dict[@"date"] ?: @"";
    item.summary = dict[@"summary"] ?: @"";
    item.content = dict[@"content"] ?: @"";
    item.priority = dict[@"priority"] ?: @"normal";
    // ★ [PRISMA-GAP] 置顶字段（"pin": true / "pinned": true / "1"；灵感：
    //   Prisma Natives/AnnouncementItem.m）。置顶项在列表里无条件排最前。
    id pinRaw = dict[@"pin"] ?: dict[@"pinned"];
    if ([pinRaw isKindOfClass:NSNumber.class]) {
        item.pinned = [(NSNumber *)pinRaw boolValue];
    } else if ([pinRaw isKindOfClass:NSString.class]) {
        NSString *s = [(NSString *)pinRaw lowercaseString];
        item.pinned = [s isEqualToString:@"true"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
    }
    item.actionURL = dict[@"action_url"] ?: @"";
    item.actionTitle = dict[@"action_title"] ?: @"";
    item.imageURL = dict[@"image_url"] ?: @"";
    return item;
}

- (NSString *)formattedDateString {
    if (self.date.length == 0) return @"";
    // 解析 ISO 日期 "2026-07-23"
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    fmt.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [fmt dateFromString:self.date];
    if (!date) return self.date;

    NSDateFormatter *displayFmt = [[NSDateFormatter alloc] init];
    displayFmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    displayFmt.dateStyle = NSDateFormatterLongStyle;
    displayFmt.timeStyle = NSDateFormatterNoStyle;
    return [displayFmt stringFromDate:date];
}

@end
