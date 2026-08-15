import { routerStore, type BoardSlot } from '../store/RouterStore'
import { TopicListPanel } from './TopicListPanel'
import { SearchPanel } from './SearchPanel'

@Component
export struct BoardRouter {
  @Prop boardSlot: BoardSlot | null
  @StorageProp('currentBreakpoint') currentBreakpoint: string = 'sm'

  build() {
    Column() {
      if (this.boardSlot) {
        Column() {
          if (this.boardSlot.type === 'search') {
            SearchPanel({
              boardFid: this.boardSlot.fid,
              boardStid: this.boardSlot.stid,
              boardName: this.boardSlot.name,
              onExitBoardScope: (): void => {
                // 版块内搜索一键切回全局搜索
                routerStore.navigateSearch()
              }
            })
          } else {
            TopicListPanel({
              boardFid: this.boardSlot.fid,
              boardName: this.boardSlot.name,
              boardStid: this.boardSlot.stid,
              showBack: this.currentBreakpoint === 'sm',
              isFavorites: this.boardSlot.fid === -9999,
              authorid: this.boardSlot.authorid,
              favor: this.boardSlot.favor,
              searchKey: this.boardSlot.searchKey,
              author: this.boardSlot.author,
              searchpost: this.boardSlot.searchpost
            })
          }
        }
        .width('100%').height('100%')
        .id(`board_${this.boardSlot.fid}_${this.boardSlot.type}`) // 增加 ID 识别
        .transition(
          TransitionEffect.asymmetric(
            // 进场：从右侧滑入
            TransitionEffect.move(TransitionEdge.END)
              .combine(TransitionEffect.OPACITY)
              .animation({ duration: 450, curve: Curve.FastOutSlowIn }),
            // 离场：向右侧滑出
            TransitionEffect.move(TransitionEdge.END)
              .combine(TransitionEffect.OPACITY)
              .animation({ duration: 450, curve: Curve.FastOutSlowIn })
          )
        )
      }
    }
    .width('100%').height('100%')
  }
}