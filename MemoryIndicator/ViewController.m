//
//  ViewController.m
//  MemoryIndicator
//
//  Created by 马浩萌 on 2024/2/6.
//

#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController
{
    char *mem;
    NSMutableData *data;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.

}

- (IBAction)click:(id)sender {
    data = [NSMutableData dataWithLength:51 * 1024 * 1024];
}

- (IBAction)expanClick:(id)sender {
    NSData *tData = [NSMutableData dataWithLength:1024*1024];
    [data appendData:tData];
}

- (IBAction)deClick:(id)sender {
    data = nil;
}

@end
