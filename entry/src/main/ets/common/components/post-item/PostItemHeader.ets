import { AppColors } from '../../constants/Constants'
import { formatTime } from '../../utils/Utils'
import { Avatar } from '../Avatar'
import { AnonymousName } from '../AnonymousName'
import { PostInfo } from '../../../model/PostInfo'
import { appStore } from '../../../store/AppStore'

/**
 * 帖子 Header 行子组件。
 *
 * 负责渲染帖子顶部的头像、作者名、备注、楼主标记、用户组、发帖时间、楼层号。
 * 点击 Header 区域（非匿名时）会回调 onProfileClick，传入点击的屏幕坐标，
 * 供父组件弹出用户资料浮层。
 */
@Component
export struct PostItemHeader {
  /** 所属帖子信息（@Prop 值拷贝） */
  @Prop post: PostInfo = new PostInfo()
  /** 是否为楼主（主题作者），决定是否显示「楼主」标记 */
  @Prop isTopicAuthor: boolean = false
  /** 点击用户资料回调，传入 uid 与点击位置的屏幕坐标 */
  onProfileClick: (uid: string, screenX: number, screenY: number) => void =
    (_uid: string, _x: number, _y: number) => {}

  build() {
    Row() {
      Row() {
        Avatar({ avatar: this.post.avatar, uid: String(this.post.authorid), name: this.post.author, avatarSize: 32 })

        Column() {
          Row() {
            AnonymousName({ author: this.post.author, isAnonymous: this.post.isanonymous, fontSize: 14, normalColor: AppColors.primary, isMuted: this.post.isMuted })
            if (this.post.userNote && this.post.userNote.length > 0) {
              Text('(' + this.post.userNote + ')')
                .fontSize(11).fontColor(AppColors.warning).margin({ left: 4 })
            }
            if (this.isTopicAuthor) {
              Text('楼主').fontSize(11).fontColor(AppColors.primary).fontWeight(FontWeight.Medium)
                .margin({ left: 4 })
            }
          }
          Row() {
            if (this.post.memberGroup && this.post.memberGroup.length > 0) {
              Text(this.post.memberGroup).fontSize(11).fontColor(AppColors.textTertiary)
            }
            Text(formatTime(Number(this.post.postdate))).fontSize(11).fontColor(AppColors.textTertiary).margin({ left: 6 })
          }
        }.alignItems(HorizontalAlign.Start).margin({ left: 8 }).layoutWeight(1)
      }.layoutWeight(1)
      .onClick((event: ClickEvent) => {
        if (this.post.isanonymous) {
          appStore.showToast('该用户已匿名')
          return
        }
        const uid = String(this.post.authorid)
        if (uid) {
          this.onProfileClick(uid, event.windowX, event.windowY)
        }
      })

      Text(this.post.lou === 0 ? '楼主' : this.post.lou === 1 ? '沙发' : `#${this.post.lou}`)
        .fontSize(13).fontColor(AppColors.textTertiary)
    }.width('100%')
  }
}
