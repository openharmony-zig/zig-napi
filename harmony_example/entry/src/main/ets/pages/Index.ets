import { hilog } from '@kit.PerformanceAnalysisKit';
import testNapi from 'libhello.so';
import buffer from '@ohos.buffer';

const DOMAIN = 0x0000;

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';

  aboutToAppear(): void {
    const napi = testNapi;

    const buf = napi.create_buffer();

    const buff = buffer.from([1,2,3]);
    const ret = napi.get_buffer(buff.buffer);
    console.log(`${ret}`)

    const buff3 = buffer.from("hello world");
    const ret1 = napi.get_buffer_as_string(buff3.buffer);

    console.log(`${ret1}`)
  }

  build() {
    Row() {
      Column() {
        Text(this.message)
          .fontSize($r('app.float.page_text_font_size'))
          .fontWeight(FontWeight.Bold)
          .onClick(() => {
            this.message = 'Welcome';
          })
      }
      .width('100%')
    }
    .height('100%')
  }
}
