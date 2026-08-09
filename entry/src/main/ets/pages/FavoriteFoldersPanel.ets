import { appStore } from '../store/AppStore'
import { routerStore, Screen } from '../store/RouterStore'
import { FavoriteMembershipState, FavoriteTopicFolder } from '../model/Favorite'
import { ApiResult, TopicFavoriteResult } from '../model/NgaApiResults'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { EmptyStateView, ErrorStateView, LoadingStateView } from '../common/components/PageStateView'
import { ConfirmDialog } from '../common/dialogs/Dialogs'
import { FavoriteFolderNameDialog } from '../common/dialogs/FavoriteFolderDialogs'
import { PageScope } from '../common/concurrency/PageScope'
import { KEY_IMMERSIVE_MATERIAL_ENABLED } from '../common/constants/AppStorageKeys'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'

/**
 * NGA 主题收藏夹管理与主题归档选择面板。
 */
@Component
export struct FavoriteFoldersPanel {
  /**
   * 需要选择收藏夹的主题 ID；为空时进入收藏夹管理模式。
   */
  @Prop topicId: string = ''
  /**
   * 当前展示的收藏夹列表快照。
   */
  @State folders: FavoriteTopicFolder[] = []
  /**
   * 是否正在刷新收藏夹列表。
   */
  @State refreshing: boolean = false
  /**
   * 当前展开管理操作的收藏夹 ID。
   */
  @State expandedFolderId: string = ''
  /**
   * 当前正在执行操作的收藏夹 ID。
   */
  @State mutatingFolderId: string = ''
  /**
   * 收藏夹列表变更版本号。
   */
  @StorageProp('favoriteFolderVersion') @Watch('onFavoriteFolderVersionChange')
  favoriteFolderVersion: number = 0
  /**
   * 主题收藏关系变更版本号。
   */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange')
  favoriteTopicVersion: number = 0
  /**
   * 状态栏高度。
   */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 是否启用沉浸式材质。 */
  @StorageProp(KEY_IMMERSIVE_MATERIAL_ENABLED) materialEnabled: boolean = true
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 收藏夹列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  /**
   * 收藏夹名称编辑对话框控制器。
   */
  private nameDialogController?: CustomDialogController
  /**
   * 删除收藏夹确认对话框控制器。
   */
  private deleteDialogController?: CustomDialogController
  /**
   * 页面存活与会话代际作用域。
   */
  private scope: PageScope = new PageScope()
  /**
   * 当前页面会话代际。
   */
  private pageScopeGeneration: number = 0

  /** 按列表绝对滚动偏移同步标题栏视觉效果。 */
  private syncTitleScrollEffect(): void {
    const progress: number = TitleScrollEffect.getProgress(
      this.scroller.currentOffset().yOffset,
      this.statusBarHeight
    )
    if (TitleScrollEffect.shouldUpdateProgress(this.titleScrollEffectProgress, progress)) {
      this.titleScrollEffectProgress = progress
    }
  }

  /**
   * 初始化页面快照并从 NGA 服务端加载收藏夹。
   */
  aboutToAppear(): void {
    this.pageScopeGeneration = this.scope.begin()
    this.refreshing = false
    this.mutatingFolderId = ''
    this.syncFromStore()
    this.refreshFolders(true)
  }

  /**
   * 释放页面动态创建的对话框。
   */
  aboutToDisappear(): void {
    this.scope.end()
    this.nameDialogController = undefined
    this.deleteDialogController = undefined
  }

  /**
   * 响应收藏夹列表变化。
   */
  private onFavoriteFolderVersionChange(): void {
    if (!this.scope.isAlive()) {
      return
    }
    this.syncFromStore()
  }

  /**
   * 响应主题收藏关系变化。
   */
  private onFavoriteTopicVersionChange(): void {
    if (!this.scope.isAlive()) {
      return
    }
    this.syncFromStore()
  }

  /**
   * 从全局收藏 Store 同步页面快照。
   */
  private syncFromStore(): void {
    this.folders = appStore.favoriteStore.getFolders()
    if (this.folders.length === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  /**
   * 构建仅包含当前行可见状态的收藏夹行键。
   *
   * @param folder - 收藏夹模型
   * @returns ArkUI 收藏夹行唯一键
   */
  private folderRenderKey(folder: FavoriteTopicFolder): string {
    const defaultFlag: string = folder.isDefault ? '1' : '0'
    const membershipState: FavoriteMembershipState = this.topicId.length > 0
      ? appStore.favoriteStore.getTopicFolderState(this.topicId, folder.id)
      : FavoriteMembershipState.UNKNOWN
    return `${folder.id}:${folder.name}:${folder.topicCount}:${defaultFlag}:${membershipState}`
  }

  /**
   * 刷新服务端收藏夹列表。
   *
   * @param force - 是否强制发起网络刷新
   */
  private async refreshFolders(force: boolean): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration) || this.refreshing) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    this.refreshing = true
    const success: boolean = force
      ? await appStore.favoriteStore.refreshFolders(true)
      : await appStore.favoriteStore.ensureFolders()
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    this.refreshing = false
    this.syncFromStore()
    if (!success && this.folders.length > 0) {
      appStore.showToast(appStore.favoriteStore.error || '刷新收藏夹失败')
    }
  }

  /**
   * 打开新建收藏夹对话框。
   */
  private showCreateFolderDialog(): void {
    this.nameDialogController = new CustomDialogController({
      builder: FavoriteFolderNameDialog({
        title: '新建收藏夹',
        confirmLabel: this.topicId.length > 0 ? '创建并收藏' : '创建',
        onConfirm: (name: string): void => {
          this.createFolder(name)
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    })
    this.nameDialogController.open()
  }

  /**
   * 新建收藏夹，并在选择模式下把当前主题归入新收藏夹。
   *
   * @param name - 新收藏夹名称
   */
  private async createFolder(name: string): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration)) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    const topicId: string = this.topicId
    this.mutatingFolderId = '__new__'
    const folder: FavoriteTopicFolder | null = await appStore.favoriteStore.createFolder(name)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    if (folder === null) {
      this.mutatingFolderId = ''
      appStore.showToast(appStore.favoriteStore.error || '新建收藏夹失败')
      return
    }
    if (topicId.length > 0) {
      const result: TopicFavoriteResult = await appStore.favoriteStore.setTopicFavorite(
        topicId, folder.id, true)
      if (!this.scope.isActive(pageGeneration)) {
        return
      }
      if (!result.ok) {
        this.mutatingFolderId = ''
        appStore.showToast(result.error || '收藏失败')
        return
      }
      appStore.showToast(`已收藏到“${folder.name}”`)
    } else {
      appStore.showToast(`已创建“${folder.name}”`)
    }
    this.mutatingFolderId = ''
    this.syncFromStore()
  }

  /**
   * 打开收藏夹重命名对话框。
   *
   * @param folder - 待重命名收藏夹
   */
  private showRenameFolderDialog(folder: FavoriteTopicFolder): void {
    const folderId: string = folder.id
    this.nameDialogController = new CustomDialogController({
      builder: FavoriteFolderNameDialog({
        title: '重命名收藏夹',
        initialName: folder.name,
        confirmLabel: '保存',
        onConfirm: (name: string): void => {
          this.renameFolder(folderId, name)
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    })
    this.nameDialogController.open()
  }

  /**
   * 重命名指定收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   * @param name - 新名称
   */
  private async renameFolder(folderId: string, name: string): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration)) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    this.mutatingFolderId = folderId
    const result: ApiResult = await appStore.favoriteStore.renameFolder(folderId, name)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    this.mutatingFolderId = ''
    this.expandedFolderId = ''
    this.syncFromStore()
    appStore.showToast(result.ok ? '收藏夹已重命名' : result.error || '重命名失败')
  }

  /**
   * 打开删除收藏夹确认对话框。
   *
   * @param folder - 待删除收藏夹
   */
  private showDeleteFolderDialog(folder: FavoriteTopicFolder): void {
    const folderId: string = folder.id
    const folderName: string = folder.name
    this.deleteDialogController = new CustomDialogController({
      builder: ConfirmDialog({
        title: '删除收藏夹',
        message: `确定删除“${folderName}”以及其中的全部收藏关系吗？`,
        confirmLabel: '删除',
        destructive: true,
        onConfirm: (): void => {
          this.deleteFolder(folderId)
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    })
    this.deleteDialogController.open()
  }

  /**
   * 删除指定收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   */
  private async deleteFolder(folderId: string): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration)) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    this.mutatingFolderId = folderId
    const result: ApiResult = await appStore.favoriteStore.deleteFolder(folderId)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    this.mutatingFolderId = ''
    this.expandedFolderId = ''
    this.syncFromStore()
    appStore.showToast(result.ok ? '收藏夹已删除' : result.error || '删除收藏夹失败')
  }

  /**
   * 将指定收藏夹设为默认收藏夹。
   *
   * @param folderId - 收藏夹服务端 ID
   */
  private async setDefaultFolder(folderId: string): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration)) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    this.mutatingFolderId = folderId
    const result: ApiResult = await appStore.favoriteStore.setDefaultFolder(folderId)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    this.mutatingFolderId = ''
    this.expandedFolderId = ''
    this.syncFromStore()
    appStore.showToast(result.ok ? '已设为默认收藏夹' : result.error || '设置默认收藏夹失败')
  }

  /**
   * 切换当前主题在指定收藏夹中的成员状态。
   *
   * @param folder - 目标收藏夹
   */
  private async toggleTopicFolder(folder: FavoriteTopicFolder): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration) || this.topicId.length === 0 ||
      this.mutatingFolderId.length > 0) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    const topicId: string = this.topicId
    const state: FavoriteMembershipState = appStore.favoriteStore.getTopicFolderState(
      topicId, folder.id)
    const favored: boolean = state === FavoriteMembershipState.FAVORED
    this.mutatingFolderId = folder.id
    const result: TopicFavoriteResult = await appStore.favoriteStore.setTopicFavorite(
      topicId, folder.id, !favored)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    this.mutatingFolderId = ''
    this.syncFromStore()
    if (result.ok) {
      appStore.showToast(favored ? `已从“${folder.name}”移除` : `已收藏到“${folder.name}”`)
    } else {
      appStore.showToast(result.error || '修改收藏失败')
    }
  }

  /**
   * 打开指定收藏夹的主题列表。
   *
   * @param folder - 目标收藏夹
   */
  private openFolder(folder: FavoriteTopicFolder): void {
    routerStore.navigateActivity(Screen.topicList(folder.name, 0, '', folder.id))
  }

  /**
   * 构建单个收藏夹条目。
   *
   * @param folder - 收藏夹模型
   */
  @Builder
  private FolderRow(folder: FavoriteTopicFolder) {
    Column() {
      Row() {
        Stack() {
          Image($r('app.media.profile_favorites'))
            .width(20)
            .height(20)
            .fillColor(folder.isDefault ? AppColors.primary : AppColors.textSecondary)
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(folder.isDefault ? AppColors.primaryLight : AppColors.bgSecondary)

        Column() {
          Row() {
            Text(folder.name || '未命名收藏夹')
              .fontSize(16)
              .fontColor(AppColors.textPrimary)
              .fontWeight(folder.isDefault ? FontWeight.Medium : FontWeight.Normal)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (folder.isDefault) {
              Text('默认')
                .fontSize(11)
                .fontColor(AppColors.primary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .margin({ left: 8 })
                .backgroundColor(AppColors.primaryLight)
                .borderRadius(5)
            }
          }
          .width('100%')
          Text(`${folder.topicCount} 个主题 · #${folder.id}`)
            .fontSize(12)
            .fontColor(AppColors.textTertiary)
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          if (this.topicId.length > 0) {
            this.toggleTopicFolder(folder)
          } else {
            this.openFolder(folder)
          }
        })

        if (this.mutatingFolderId === folder.id) {
          LoadingProgress().width(20).height(20).color(AppColors.primary).margin({ left: 12 })
        } else if (this.topicId.length > 0) {
          Stack() {
            if (appStore.favoriteStore.getTopicFolderState(this.topicId, folder.id) ===
              FavoriteMembershipState.FAVORED) {
              Image($r('app.media.icon_checkmark'))
                .width(18)
                .height(18)
                .fillColor(AppColors.primary)
            } else if (appStore.favoriteStore.getTopicFolderState(this.topicId, folder.id) ===
              FavoriteMembershipState.UNKNOWN) {
              Text('未确认')
                .fontSize(10)
                .fontColor(AppColors.textTertiary)
            }
          }
          .width(52)
          .height(40)
          .onClick((): void => {
            this.toggleTopicFolder(folder)
          })
        } else {
          Stack() {
            Image($r('app.media.icon_more'))
              .width(20)
              .height(20)
              .fillColor(AppColors.textSecondary)
          }
          .width(40)
          .height(40)
          .onClick((): void => {
            this.expandedFolderId = this.expandedFolderId === folder.id ? '' : folder.id
          })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.topicId.length === 0 && this.expandedFolderId === folder.id) {
        Divider().color(AppColors.separator).margin({ left: 68 })
        Row() {
          if (!folder.isDefault) {
            Text('设为默认')
              .fontSize(13)
              .fontColor(AppColors.primary)
              .onClick((): void => {
                this.setDefaultFolder(folder.id)
              })
          }
          Text('重命名')
            .fontSize(13)
            .fontColor(AppColors.primary)
            .margin({ left: folder.isDefault ? 0 : 24 })
            .onClick((): void => {
              this.showRenameFolderDialog(folder)
            })
          Text('删除')
            .fontSize(13)
            .fontColor(AppColors.destructive)
            .margin({ left: 24 })
            .onClick((): void => {
              this.showDeleteFolderDialog(folder)
            })
        }
        .width('100%')
        .height(42)
        .padding({ left: 68, right: 20 })
        .justifyContent(FlexAlign.End)
      }
    }
    .width('100%')
  }

  /**
   * 构建收藏夹管理或主题归档选择页面。
   */
  build() {
    Stack() {
      Column() {
        if (this.refreshing && this.folders.length === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            LoadingStateView()
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.folders.length === 0 && appStore.favoriteStore.error.length > 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            ErrorStateView({
              msg: appStore.favoriteStore.error,
              onRetry: (): void => {
                this.refreshFolders(true)
              }
            })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else if (this.folders.length === 0) {
          Row().width('100%').height(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          Column() {
            EmptyStateView({ msg: '暂无收藏夹', icon: $r('app.media.profile_favorites') })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            ForEach(this.folders, (folder: FavoriteTopicFolder): void => {
              ListItem() {
                this.FolderRow(folder)
              }
            }, (folder: FavoriteTopicFolder): string => this.folderRenderKey(folder))
          }
          .width('100%')
          .layoutWeight(1)
          .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
          .divider({ strokeWidth: 0.5, color: AppColors.separator })
          .edgeEffect(EdgeEffect.Spring)
          .linearGradientBlur(
            TitleScrollEffect.getBlurRadius(this.materialEnabled, this.titleScrollEffectProgress),
            {
              fractionStops: TitleScrollEffect.getBlurStops(this.listViewportHeight, this.statusBarHeight),
              direction: GradientDirection.Bottom
            }
          )
          .onAreaChange((_oldValue: Area, newValue: Area): void => {
            if (typeof newValue.height === 'number' && newValue.height > 0 &&
              newValue.height !== this.listViewportHeight) {
              this.listViewportHeight = newValue.height
            }
          })
          .onDidScroll((): void => {
            this.syncTitleScrollEffect()
          })
          .onAppear((): void => {
            this.syncTitleScrollEffect()
          })
        }
      }
      .width('100%')
      .height('100%')

      PanelNavBar({
        title: this.topicId.length > 0 ? '收藏到…' : '收藏主题',
        scrollEffectProgress: this.titleScrollEffectProgress,
        rightLabel: '+ 新建',
        onRightClick: (): void => {
          this.showCreateFolderDialog()
        }
      })
      .width('100%')
      .position({ x: 0, y: 0 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColors.bg)
  }
}
