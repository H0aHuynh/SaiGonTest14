//
//  ViewController.m
//  pre-jailbreak
//
//  Created by Quote on 2021/2/19.
//

#import "ViewController.h"
#include "mycommon.h"
#include "../utils/patchfinder64.h"
#include "../utils/kerneldec/kerneldec.h"
#include "../utils/utils.h"
#include <mach/error.h>
#include <sys/utsname.h>
uint64_t allprocfind;
int kernel(void){
    int rv;
    uint64_t base = 0;
    NSError* error = nil;
    unlink("/tmp/kernel.tmp");
    unlink("/tmp/kernel.dec.tmp");
    NSString* prebootPath = @"/private/preboot/active";
        
        NSString* activeFolderName = [NSString stringWithContentsOfFile:prebootPath];
        
        NSString* kernelPath = [NSString stringWithFormat:@"/private/preboot/%@/System/Library/Caches/com.apple.kernelcaches/kernelcache", activeFolderName];
        
        NSString* workspaceKernelPath = @"/tmp/kernel.tmp";
        
        [[NSFileManager defaultManager] copyItemAtPath:kernelPath toPath:workspaceKernelPath error:&error];
        
        if(error){
            printf("Failed copy");
            exit(1);
        }
        
        FILE* file_input = fopen([workspaceKernelPath UTF8String], "rb");
        FILE* file_output = fopen("/tmp/kernel.dec.tmp", "wb");
        
        if(file_output == NULL || file_input == NULL){
            printf("Failed open /tmp/kernel.tmp");
            exit(1);
        }
        
        decompress_kernel(file_input, file_output, NULL, true);
        
        fclose(file_input);
        fclose(file_output);
        
        rv = init_kernel(g_exp.kernel_slide + 0xFFFFFFF007004000, "/tmp/kernel.dec.tmp");
    
    if (rv != KERN_SUCCESS) {
        util_error("%d", rv);
    }
        
        
    uint64_t  off_allproc = find_vm_map_remap();
    //uint64_t   off_kauth_cred_table_anchor = find_kauth_cred_table_anchor();
        
        printf("all_proc : 0x%llx\n", off_allproc);
       // printf("kauth_cred_table_anchor : 0x%llx\n", off_kauth_cred_table_anchor);

        term_kernel();
    unlink("/tmp/kernel.tmp");
    unlink("/tmp/kernel.dec.tmp");
    return 0;
}


extern void (*log_UI)(const char *text);
void log_toView(const char *text);

static ViewController *sharedController = nil;

@interface ViewController ()
@property (weak, nonatomic) IBOutlet UIButton *goButton;
@property (weak, nonatomic) IBOutlet UITextView *textView;

@end

char *Build_resource_path(char *filename)
{
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
    if(filename == NULL) {
        return strdup([[resourcePath stringByAppendingString:@"/"] UTF8String]);
    }
    return strdup([[resourcePath stringByAppendingPathComponent:[NSString stringWithUTF8String:filename]] UTF8String]);
}

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.

    sharedController = self;

    self.goButton.layer.cornerRadius = 15;
    self.textView.text = @"";
    // 只有当前行中不包含空格等字符时才生效，sad
    self.textView.textContainer.lineBreakMode = NSLineBreakByCharWrapping;
    [self.goButton setEnabled:FALSE];
    self.goButton.backgroundColor = UIColor.lightGrayColor;

    log_UI = log_toView;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        sys_init();
        print_os_details();
        dispatch_sync( dispatch_get_main_queue(), ^{
            [[sharedController goButton] setEnabled:TRUE];
            [sharedController goButton].backgroundColor = UIColor.systemBlueColor;
        });
    });
}

- (IBAction)exploitTouchUp:(id)sender {
    NSString *enjoyStr = @"Enjoy it :)";
    if ([[[self.goButton titleLabel] text] isEqualToString:enjoyStr]) {
        return;
    }
    [self.goButton setTitle:@"Exploiting" forState:UIControlStateDisabled];
    [self.goButton setEnabled:FALSE];
    self.goButton.backgroundColor = UIColor.lightGrayColor;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        void exploit_main(void);
        exploit_main();
        kernel();
        
        
        dispatch_sync( dispatch_get_main_queue(), ^{
            [[sharedController goButton] setTitle:enjoyStr forState:UIControlStateNormal];
            [[sharedController goButton] setEnabled:TRUE];
            [sharedController goButton].backgroundColor = UIColor.systemGreenColor;
        });
    });
}

@end

void log_toView(const char *text)
{
    dispatch_sync( dispatch_get_main_queue(), ^{
        [[sharedController textView] insertText:[NSString stringWithUTF8String:text]];
        [[sharedController textView] scrollRangeToVisible:NSMakeRange([sharedController textView].text.length, 1)];
    });
}
