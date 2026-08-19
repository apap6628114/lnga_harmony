/**
 * 收藏与保存融合面板 - 在线收藏 / 离线保存 双 Tab。
 *
 * 由个人主页「收藏主题」入口打开。遵循 docs/TITLE_LIST_DESIGN.md 标题区与
 * 列表沉浸联动契约（以 NotificationPanel 为双 Tab 实例）：
 * - 筛选条（SegmentButton 胶囊）为 List 首个元素，随滚动穿越标题区；
 * - 标题区走 PanelNavBar + contentStartOffset + linearGradientBlur +
 *   TitleScrollEffect 联动体系；
 * - 标题区按钮随 Tab 协调：在线收藏 = 新建收藏夹，离线保存 = 导入 / 导出。
 * 列表行透明（底色由页面 Stack 提供），避免模糊化过渡带。
 */

import { appStore } from '../store/AppStore'
import { routerStore, Screen, ThreadSource } from '../store/RouterStore'
import { picker, fileIo } from '@kit.CoreFileKit'
import { common } from '@kit.AbilityKit'
import { AppColors } from '../common/constants/Constants'
import { PanelNavBar } from '../common/components/PanelNavBar'
import { LoadingStateView, ErrorStateView, EmptyStateView } from '../common/components/PageStateView'
import { ConfirmDialog } from '../common/dialogs/Dialogs'
import { FavoriteFolderNameDialog } from '../common/dialogs/FavoriteFolderDialogs'
import { PageScope } from '../common/concurrency/PageScope'
import { TitleScrollEffect } from '../common/utils/TitleScrollEffect'
import { formatTime } from '../common/utils/Utils'
import { FavoriteTopicFolder } from '../model/Favorite'
import { ApiResult } from '../model/NgaApiResults'
import { SavedThread } from '../model/SavedThread'
import { ImportResult } from '../store/SavedThreadStore'
import { Logger, DOMAIN_UI, formatError } from '../common/utils/Logger'
import {
  SegmentButton,
  SegmentButtonOptions,
  SegmentButtonItemTuple
} from '@kit.ArkUI'

const logger = new Logger(DOMAIN_UI, 'FavoriteSavedPanel')

/** 在线收藏 Tab。 */
const TAB_FAVORITES: number = 0
/** 离线保存 Tab。 */
const TAB_SAVED: number = 1

/** 导入选择的最大文件数。 */
const IMPORT_MAX_FILES: number = 50

@Component
export struct FavoriteSavedPanel {
  /** 当前筛选 Tab（0=在线收藏，1=离线保存）。 */
  @State activeTab: number = 0
  /** 筛选条分段按钮选项（原生 SegmentButton，胶囊单选）。 */
  @State tabOptions: SegmentButtonOptions = SegmentButtonOptions.capsule({
    buttons: [
      { text: '在线收藏' },
      { text: '离线保存' }
    ] as SegmentButtonItemTuple,
    multiply: false,
    fontColor: AppColors.textSecondary,
    selectedFontColor: AppColors.primary,
    fontSize: 13,
    selectedFontSize: 13,
    fontWeight: FontWeight.Normal,
    selectedFontWeight: FontWeight.Bold,
    backgroundColor: AppColors.bgSecondary,
    selectedBackgroundColor: AppColors.primaryLight,
  })
  /** 筛选条分段按钮选中项（SegmentButton 双向绑定，单选取 [index]）。 */
  @State tabSelected: number[] = [0]
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  /** 标题栏渐变模糊与偏色的滚动联动进度。 */
  @State titleScrollEffectProgress: number = 0
  /** 列表当前视口高度。 */
  @State listViewportHeight: number = 1
  /** 标题区主按钮图标（随 Tab 切换）。 */
  @State tabRightIcon: ResourceStr = $r('app.media.icon_nav_add')
  /** 标题区次按钮图标（随 Tab 切换，空串隐藏）。 */
  @State tabSecondaryIcon: ResourceStr = ''
  /** 标题区主按钮无障碍名。 */
  @State tabRightAccessibility: string = '新建收藏夹'
  /** 标题区次按钮无障碍名。 */
  @State tabSecondaryAccessibility: string = ''
  /** 是否正在导入（避免重复触发选择器）。 */
  @State importing: boolean = false

  // ---- 在线收藏（服务端收藏夹管理）状态 ----
  /** 收藏夹列表快照。 */
  @State folders: FavoriteTopicFolder[] = []
  /** 是否正在刷新收藏夹列表。 */
  @State refreshing: boolean = false
  /** 当前展开管理操作的收藏夹 ID。 */
  @State expandedFolderId: string = ''
  /** 当前正在执行操作的收藏夹 ID。 */
  @State mutatingFolderId: string = ''
  /** 收藏夹列表变更版本号。 */
  @StorageProp('favoriteFolderVersion') @Watch('onFavoriteFolderVersionChange')
  favoriteFolderVersion: number = 0
  /** 主题收藏关系变更版本号。 */
  @StorageProp('favoriteTopicVersion') @Watch('onFavoriteTopicVersionChange')
  favoriteTopicVersion: number = 0

  // ---- 离线保存（本地存档）状态 ----
  /** 存档列表快照（按保存时间降序）。 */
  @State savedItems: SavedThread[] = []
  /** 存档版本号（保存/删除/导入时 +1 触发刷新）。 */
  @StorageProp('savedThreadVersion') @Watch('onSavedThreadVersionChange')
  savedThreadVersion: number = 0
  /** 待删除的存档条目。 */
  private removeTarget: SavedThread | null = null

  /** 列表滚动控制器。 */
  private scroller: Scroller = new Scroller()
  /** 筛选条在窗口中的底部纵坐标（onAreaChange 实时采集，供状态视图撑满估算）。 */
  private sortBarBottomY: number = 0
  /** 页面存活与会话代际作用域。 */
  private scope: PageScope = new PageScope()
  /** 当前页面会话代际。 */
  private pageScopeGeneration: number = 0
  /** 收藏夹名称（新建/重命名）对话框控制器。 */
  private nameDialogController?: CustomDialogController
  /** 删除收藏夹确认对话框控制器。 */
  private folderDeleteDialogController?: CustomDialogController
  /** 删除存档确认对话框控制器。 */
  private savedDeleteDialogController?: CustomDialogController
  /** 清空存档确认对话框控制器。 */
  private clearDialogController?: CustomDialogController

  aboutToAppear(): void {
    this.pageScopeGeneration = this.scope.begin()
    this.tabSelected = [this.activeTab]
    this.syncFoldersFromStore()
    this.refreshSaved()
    if (this.activeTab === TAB_FAVORITES) {
      this.refreshFolders(true)
    }
  }

  aboutToDisappear(): void {
    this.scope.end()
    this.nameDialogController = undefined
    this.folderDeleteDialogController = undefined
    this.savedDeleteDialogController = undefined
    this.clearDialogController = undefined
  }

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

  /** 状态视图撑满筛选条下方的列表可视区高度。 */
  private getStateViewHeight(): number {
    const topOffset: number = this.sortBarBottomY > 0
      ? this.sortBarBottomY
      : TitleScrollEffect.getContentStartOffset(this.statusBarHeight) + 50
    return Math.max(this.listViewportHeight - topOffset, 400)
  }

  /** 筛选条切换：更新标题区按钮组、数据源并回顶。 */
  private handleTabClicked(index: number): void {
    if (this.activeTab === index) {
      return
    }
    this.activeTab = index
    this.tabSelected = [index]
    // 切 Tab 后标题滚动进度归零，避免旧进度残留在新内容上（TITLE_LIST_DESIGN 坑 5）
    this.titleScrollEffectProgress = 0
    this.pageScopeGeneration = this.scope.begin()
    if (index === TAB_FAVORITES) {
      this.tabRightIcon = $r('app.media.icon_nav_add')
      this.tabSecondaryIcon = ''
      this.tabRightAccessibility = '新建收藏夹'
      this.tabSecondaryAccessibility = ''
      this.syncFoldersFromStore()
      this.refreshFolders(false)
    } else {
      this.tabRightIcon = $r('app.media.icon_import')
      this.tabSecondaryIcon = $r('app.media.icon_export')
      this.tabRightAccessibility = '导入存档'
      this.tabSecondaryAccessibility = '导出存档'
      this.refreshSaved()
    }
    // 内容已切换，滚动回到顶部（等待列表重建完成）
    setTimeout((): void => {
      if (this.scope.isAlive()) {
        this.scroller.scrollEdge(Edge.Top)
      }
    }, 0)
  }

  // ==================== 在线收藏：收藏夹管理 ====================

  private onFavoriteFolderVersionChange(): void {
    if (!this.scope.isAlive()) {
      return
    }
    this.syncFoldersFromStore()
  }

  private onFavoriteTopicVersionChange(): void {
    if (!this.scope.isAlive()) {
      return
    }
    this.syncFoldersFromStore()
  }

  /** 从全局收藏 Store 同步页面快照。 */
  private syncFoldersFromStore(): void {
    this.folders = appStore.favoriteStore.getFolders()
    if (this.folders.length === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  /**
   * 构建收藏夹行唯一键（管理模式：无主题成员状态参与）。
   */
  private folderRenderKey(folder: FavoriteTopicFolder): string {
    return folder.id + ':' + folder.name + ':' + String(folder.topicCount) + ':' +
      (folder.isDefault ? '1' : '0')
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
      // 请求期间已切 Tab/离开：复位刷新标记，避免回切后 refreshing 卡死导致
      // 永远无法再次刷新（乃至空列表无限 Loading）
      this.refreshing = false
      return
    }
    this.refreshing = false
    this.syncFoldersFromStore()
    if (!success && this.folders.length > 0) {
      appStore.showToast(appStore.favoriteStore.error || '刷新收藏夹失败')
    }
  }

  private showCreateFolderDialog(): void {
    this.nameDialogController = new CustomDialogController({
      builder: FavoriteFolderNameDialog({
        title: '新建收藏夹',
        confirmLabel: '创建',
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
   * 新建收藏夹（服务端）；成功后代际内同步快照。
   *
   * @param name - 新收藏夹名称
   */
  private async createFolder(name: string): Promise<void> {
    if (!this.scope.isActive(this.pageScopeGeneration)) {
      return
    }
    const pageGeneration: number = this.pageScopeGeneration
    const folder: FavoriteTopicFolder | null = await appStore.favoriteStore.createFolder(name)
    if (!this.scope.isActive(pageGeneration)) {
      return
    }
    if (folder === null) {
      appStore.showToast(appStore.favoriteStore.error || '新建收藏夹失败')
      return
    }
    appStore.showToast('已创建“' + folder.name + '”')
    this.syncFoldersFromStore()
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
    this.syncFoldersFromStore()
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
    this.folderDeleteDialogController = new CustomDialogController({
      builder: ConfirmDialog({
        title: '删除收藏夹',
        message: '确定删除“' + folderName + '”以及其中的全部收藏关系吗？',
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
    this.folderDeleteDialogController.open()
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
    this.syncFoldersFromStore()
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
    this.syncFoldersFromStore()
    appStore.showToast(result.ok ? '已设为默认收藏夹' : result.error || '设置默认收藏夹失败')
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
   * 构建单个收藏夹条目（管理模式）。
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
          Text(String(folder.topicCount) + ' 个主题 · #' + folder.id)
            .fontSize(12)
            .fontColor(AppColors.textTertiary)
            .margin({ top: 3 })
        }
        .layoutWeight(1)
        .margin({ left: 12 })
        .alignItems(HorizontalAlign.Start)
        .onClick((): void => {
          this.openFolder(folder)
        })

        if (this.mutatingFolderId === folder.id) {
          LoadingProgress().width(20).height(20).color(AppColors.primary).margin({ left: 12 })
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

      if (this.expandedFolderId === folder.id) {
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

  // ==================== 离线保存：存档列表 ====================

  private onSavedThreadVersionChange(): void {
    this.refreshSaved()
  }

  /** 从存储重载存档快照（存储层已按保存时间降序）。 */
  private refreshSaved(): void {
    this.savedItems = appStore.savedThreadStore.getAll()
    if (this.savedItems.length === 0) {
      this.titleScrollEffectProgress = 0
    }
  }

  /**
   * 条目副行文案：作者 · 页数/楼层数 · 保存时间。
   *
   * 楼层数按保存的最后一页楼层号（lastLou）为基准，与离线阅读所见一致。
   */
  private describe(item: SavedThread): string {
    const author: string = item.author.length > 0 ? item.author : '未知作者'
    return author + ' · ' + String(item.savedPages) + ' 页 / ' + String(item.lastLou) +
      ' 楼 · 保存于 ' + formatTime(item.savedAt)
  }

  /**
   * 以「保存的帖子」来源打开该帖：ThreadPanel 从本地存档读取数据渲染，
   * 不依赖网络，帖子删除后仍可完整阅读；表现与在线打开一致。
   */
  private openThread(item: SavedThread): void {
    routerStore.navigateActivity(Screen.thread(item.tid, 1, '', ThreadSource.SAVED))
  }

  /**
   * 将一组存档导出为一个 JSON 文件（不加密）。
   *
   * @param threads - 待导出的存档
   */
  private async exportThreads(threads: SavedThread[]): Promise<void> {
    if (threads.length === 0) {
      appStore.showToast('没有可导出的存档')
      return
    }
    let context: common.UIAbilityContext | null = null
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext
    } catch (e) {
      appStore.showToast('无法获取文件保存器')
      return
    }
    try {
      const documentSaveOptions: picker.DocumentSaveOptions = new picker.DocumentSaveOptions()
      if (threads.length === 1) {
        documentSaveOptions.newFileNames = ['nga_' + threads[0].tid + '_saved.json']
      } else {
        documentSaveOptions.newFileNames = ['nga_saved_threads_' + String(Date.now()) + '.json']
      }
      documentSaveOptions.fileSuffixChoices = ['JSON 存档|.json']
      const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await documentViewPicker.save(documentSaveOptions)
      if (uris.length === 0) {
        return
      }
      const content: string = appStore.savedThreadStore.serializeForExport(threads)
      const file: fileIo.File = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC)
      try {
        fileIo.writeSync(file.fd, content)
      } finally {
        fileIo.closeSync(file)
      }
      appStore.showToast('已导出 ' + String(threads.length) + ' 个帖子')
    } catch (e) {
      appStore.showToast('导出失败：' + formatError(e))
    }
  }

  /**
   * 将全部存档导出为一个 JSON 文件（不加密）。
   */
  private async exportAll(): Promise<void> {
    await this.exportThreads(appStore.savedThreadStore.getAll())
  }

  // ---------- 导入 ----------

  /**
   * 从硬盘选择存档文件并导入（冲突按覆盖处理）。
   */
  private async handleImport(): Promise<void> {
    if (this.importing) {
      return
    }
    let context: common.UIAbilityContext | null = null
    try {
      context = this.getUIContext().getHostContext() as common.UIAbilityContext
    } catch (e) {
      appStore.showToast('无法获取文件选择器')
      return
    }
    this.importing = true
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions()
      options.maxSelectNumber = IMPORT_MAX_FILES
      const documentViewPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context)
      const uris: string[] = await documentViewPicker.select(options)
      if (uris.length === 0) {
        return
      }
      let imported: number = 0
      let skipped: number = 0
      let firstError: string = ''
      for (let i = 0; i < uris.length; i++) {
        try {
          const content: string = this.readUriText(uris[i])
          const result: ImportResult = await appStore.savedThreadStore.importContent(content)
          imported += result.imported
          skipped += result.skipped
          if (result.error.length > 0 && firstError.length === 0) {
            firstError = result.error
          }
        } catch (e) {
          skipped++
          if (firstError.length === 0) {
            firstError = '读取文件失败'
          }
          logger.warn('import file failed: %{public}s', formatError(e))
        }
      }
      if (firstError.length > 0) {
        appStore.showToast('导入完成：成功 ' + String(imported) + ' 个，跳过 ' + String(skipped) + ' 个（' + firstError + '）')
      } else {
        appStore.showToast('成功导入 ' + String(imported) + ' 个帖子')
      }
    } catch (e) {
      appStore.showToast('导入失败：' + formatError(e))
    } finally {
      this.importing = false
    }
  }

  /**
   * 读取文件选择器返回的 uri 文本内容（UTF-8）。
   *
   * 使用 fileIo.readTextSync 整体读取：文件系统 API 统一接受 uri 与沙箱路径，
   * 避免手写 readSync 多块循环时因写入位置固定在 buffer 起始而覆盖已读数据。
   */
  private readUriText(uri: string): string {
    return fileIo.readTextSync(uri)
  }

  // ---------- 离线保存：删除 / 清空 ----------

  private showClearConfirm(): void {
    this.clearDialogController = new CustomDialogController({
      builder: ConfirmDialog({
        title: '清空存档',
        message: '确定要删除全部保存的帖子吗？\n此操作不可恢复',
        confirmLabel: '清空',
        destructive: true,
        icon: $r('app.media.icon_delete'),
        onConfirm: () => {
          // 存储层已 bump savedThreadVersion，刷新由 onSavedThreadVersionChange 驱动
          appStore.savedThreadStore.clear().then((): void => {
            appStore.showToast('已清空存档')
          })
        },
        onCancel: () => {}
      }),
      autoCancel: true,
      customStyle: true
    })
    this.clearDialogController?.open()
  }

  build() {
    Stack() {
      Column() {
        List({ scroller: this.scroller }) {
          ListItem() {
            Row() {
              SegmentButton({
                options: this.tabOptions,
                selectedIndexes: $tabSelected,
                onItemClicked: (index: number): void => {
                  this.handleTabClicked(index)
                }
              })
            }
            .width('100%')
            .padding({ left: '4%', right: '4%' })
            .margin({ top: 8, bottom: 6 })
            .onAreaChange((_oldValue: Area, newValue: Area): void => {
              if (typeof newValue.globalPosition.y === 'number' && typeof newValue.height === 'number') {
                this.sortBarBottomY = newValue.globalPosition.y + newValue.height
              }
            })
          }

          if (this.activeTab === TAB_FAVORITES) {
            if (this.refreshing && this.folders.length === 0) {
              ListItem() {
                Column() {
                  LoadingStateView()
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.folders.length === 0 && appStore.favoriteStore.error.length > 0) {
              ListItem() {
                Column() {
                  ErrorStateView({
                    msg: appStore.favoriteStore.error,
                    onRetry: (): void => {
                      this.refreshFolders(true)
                    }
                  })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else if (this.folders.length === 0) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '暂无收藏夹', icon: $r('app.media.profile_favorites') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else {
              ForEach(this.folders, (folder: FavoriteTopicFolder) => {
                ListItem() {
                  this.FolderRow(folder)
                }
              }, (folder: FavoriteTopicFolder) => this.folderRenderKey(folder))
            }
          } else {
            if (this.savedItems.length === 0) {
              ListItem() {
                Column() {
                  EmptyStateView({ msg: '暂无保存的帖子', icon: $r('app.media.icon_export') })
                }
                .width('100%').height(this.getStateViewHeight())
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
                .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
              }
            } else {
              ListItem() {
                Row() {
                  Text('共 ' + String(this.savedItems.length) + ' 个存档').fontSize(13).fontColor(AppColors.textTertiary).layoutWeight(1)
                  Text('清空全部').fontSize(13).fontColor(AppColors.destructive)
                    .onClick(() => {
                      this.showClearConfirm()
                    })
                }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
              }

              ForEach(this.savedItems, (item: SavedThread) => {
                ListItem() {
                  Row() {
                    Stack() {
                      Image($r('app.media.icon_export')).width(20).height(20).fillColor(AppColors.textTertiary)
                    }
                    .width(40).height(40).borderRadius(20).backgroundColor(AppColors.bgSecondary)

                    Column() {
                      Text(item.subject.length > 0 ? item.subject : '（无标题）')
                        .fontSize(15).fontColor(AppColors.textPrimary)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(this.describe(item))
                        .fontSize(13).fontColor(AppColors.textTertiary).margin({ top: 2 })
                    }
                    .layoutWeight(1).margin({ left: 12 }).alignItems(HorizontalAlign.Start)
                    .onClick(() => {
                      this.openThread(item)
                    })

                    Stack() {
                      Image($r('app.media.icon_export')).width(18).height(18).fillColor(AppColors.primary)
                    }
                    .width(36).height(36)
                    .onClick(() => {
                      this.exportThreads([item])
                    })

                    Stack() {
                      Image($r('app.media.icon_delete')).width(18).height(18).fillColor(AppColors.destructive)
                    }
                    .width(36).height(36)
                    .onClick(() => {
                      this.removeTarget = item
                      this.savedDeleteDialogController = new CustomDialogController({
                        builder: ConfirmDialog({
                          title: '删除存档',
                          message: '确定要删除该帖子的存档吗？',
                          confirmLabel: '删除',
                          destructive: true,
                          icon: $r('app.media.icon_delete'),
                          onConfirm: () => {
                            const tid: string = this.removeTarget ? this.removeTarget.tid : ''
                            this.removeTarget = null
                            if (tid.length > 0) {
                              // 存储层已 bump savedThreadVersion，刷新由 onSavedThreadVersionChange 驱动
                              appStore.savedThreadStore.remove(tid).then((): void => {
                                appStore.showToast('已删除存档')
                              }).catch((e: Error) => {
                                appStore.showToast(e.message || '删除失败')
                              })
                            }
                          },
                          onCancel: () => {
                            this.removeTarget = null
                          }
                        }),
                        autoCancel: true,
                        customStyle: true
                      })
                      this.savedDeleteDialogController?.open()
                    })
                  }
                  .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
                }
              }, (item: SavedThread) => item.tid)
            }
          }
        }
        .width('100%').layoutWeight(1)
        .scrollBar(BarState.Off)
        .contentStartOffset(TitleScrollEffect.getContentStartOffset(this.statusBarHeight))
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .edgeEffect(EdgeEffect.Spring)
        .linearGradientBlur(
          TitleScrollEffect.getBlurRadius(this.titleScrollEffectProgress),
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
      .width('100%')
      .height('100%')

      PanelNavBar({
        title: '收藏与保存',
        scrollEffectProgress: this.titleScrollEffectProgress,
        rightIcon: this.tabRightIcon,
        rightIconAccessibilityText: this.tabRightAccessibility,
        secondaryRightIcon: this.tabSecondaryIcon,
        secondaryRightIconAccessibilityText: this.tabSecondaryAccessibility,
        onRightClick: (): void => {
          if (this.activeTab === TAB_FAVORITES) {
            this.showCreateFolderDialog()
          } else {
            this.handleImport()
          }
        },
        onSecondaryRightClick: (): void => {
          if (this.activeTab === TAB_SAVED) {
            this.exportAll()
          }
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
