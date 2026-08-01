import { appStore } from '../store/AppStore'
import type { AuthState } from '../store/AuthStore'
import { FavBoard } from '../model/SocialEntries'
import { routerStore, RouterStoreClass, Screen } from '../store/RouterStore'
import { AppColors } from '../common/constants/Constants'
import { CategoryDataSource, SidebarDataSource, SidebarSection, SidebarBoardItem } from '../common/datasource/LazyDataSource'
import type { Category, BoardContent } from '../model/Forum'
import { Avatar } from '../common/components/Avatar'

@Component
export struct CommunityPanel {
  @State isLoading: boolean = true
  @State loadError: string = ''
  @State favoritesList: FavBoard[] = []
  @State selectedSectionId: string = ''
  @State private router: RouterStoreClass = routerStore
  @State private authState: AuthState = appStore.auth
  @Prop currentBreakpoint: string = 'sm'
  @StorageProp('statusBarHeight') statusBarHeight: number = 0
  @StorageProp('favVersion') @Watch('onFavVersionChange') favVersion: number = 0
  @StorageProp('catVersion') @Watch('onCatVersionChange') catVersion: number = 0
  categories: Category[] = []
  private categoriesDataSource: CategoryDataSource = new CategoryDataSource()
  private sidebarDataSource: SidebarDataSource = new SidebarDataSource()

  aboutToAppear(): void {
    this.syncFavorites()
    this.syncCategories()
    this.ensureSelectedSection()
    appStore.ensureCategories()
  }

  private onFavVersionChange(): void {
    this.syncFavorites()
    this.rebuildSidebarSections()
    this.ensureSelectedSection()
  }

  private onCatVersionChange(): void {
    this.syncCategories()
    this.ensureSelectedSection()
  }

  private syncCategories(): void {
    this.categories = appStore.cachedCategories
    this.categoriesDataSource.replaceAll(this.categories)
    this.rebuildSidebarSections()
    this.loadError = appStore.categoriesError
    if (this.categories.length > 0 || appStore.categoriesLoaded) {
      this.isLoading = false
    }
  }

  /** 确保 selectedSectionId 指向有效分区，当数据为空时置空提前返回 */
  private ensureSelectedSection(): void {
    if (this.favoritesList.length === 0 && this.categories.length === 0) {
      this.selectedSectionId = ''
      return
    }
    if (this.selectedSectionId !== '' && this.selectedSectionId !== '__fav__') {
      const found = this.categories.some((cat: Category) => cat.id === this.selectedSectionId)
      if (found) return
    }
    if (this.selectedSectionId === '__fav__' && this.favoritesList.length > 0) return
    if (this.favoritesList.length > 0) {
      this.selectedSectionId = '__fav__'
    } else if (this.categories.length > 0) {
      this.selectedSectionId = this.categories[0].id
    }
  }

  private syncFavorites(): void {
    this.favoritesList = [...appStore.settings.favorites]
  }

  private hasSections(): boolean {
    return this.favoritesList.length > 0 || this.categories.length > 0
  }

  private retryCategories(): void {
    this.isLoading = true
    this.loadError = ''
    appStore.ensureCategories()
  }

  private rebuildSidebarSections(): void {
    const prevCollapsed = new Map<string, boolean>()
    const count = this.sidebarDataSource.totalCount()
    for (let i = 0; i < count; i++) {
      const s = this.sidebarDataSource.getData(i)
      prevCollapsed.set(s.id, s.collapsed)
    }
    const sections: SidebarSection[] = []
    if (this.favoritesList.length > 0) {
      const favItems: SidebarBoardItem[] = []
      for (const fav of this.favoritesList) {
        favItems.push({ fid: fav.fid, stid: fav.stid, name: fav.name })
      }
      sections.push({ id: '__fav__', name: '收藏板块', items: favItems, collapsed: false, collapsible: false })
    }
    for (const cat of this.categories) {
      const boards: SidebarBoardItem[] = []
      const seen = new Set<number>()
      if (cat.sub && Array.isArray(cat.sub)) {
        for (const sub of cat.sub) {
          if (sub.content && Array.isArray(sub.content)) {
            for (const board of sub.content) {
              if (!seen.has(board.fid)) {
                seen.add(board.fid)
                boards.push({ fid: board.fid, stid: board.stid, name: board.name })
              }
            }
          }
        }
      }
      const prev = prevCollapsed.get(cat.id)
      sections.push({ id: cat.id, name: cat.name, items: boards, collapsed: prev !== undefined ? prev : true, collapsible: true })
    }
    this.sidebarDataSource.replaceAll(sections)
  }

  build() {
    if (this.currentBreakpoint === 'sm') {
      if (this.isLoading) {
        Column() {
          LoadingProgress().width(24).height(24).color(AppColors.textTertiary)
        }
        .width('100%').height('100%')
        .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      } else if (!this.hasSections()) {
        this.CategoryFallbackContent()
      } else {
        this.MobileTwoPanelContent()
      }
    } else {
      this.SidebarListContent()
    }
  }

  private isFavBoard(fid: number): boolean {
    for (const f of this.favoritesList) {
      if (f.fid === fid) return true
    }
    return false
  }

  private handleToggleFav(fid: number, name: string): void {
    if (this.isFavBoard(fid)) {
      appStore.settingsStore.removeFavorite(fid)
    } else {
      const fb = new FavBoard()
      fb.fid = fid
      fb.stid = fid
      fb.name = name
      appStore.settingsStore.addFavorite(fb)
    }
  }

  @Builder
  SidebarListContent() {
    if (this.isLoading) {
      Column() {
        LoadingProgress().width(24).height(24).color(AppColors.textTertiary)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    } else if (!this.hasSections()) {
      this.CategoryFallbackContent()
    } else {
      List({ space: 0 }) {
        LazyForEach(this.sidebarDataSource, (section: SidebarSection) => {
          ListItemGroup({
            header: this.SidebarSectionHeader(section)
          }) {
            if (!section.collapsed) {
              ForEach(section.items, (item: SidebarBoardItem) => {
                ListItem() {
                  Row() {
                    Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${item.fid}.png`)
                      .width(section.collapsible ? 18 : 20)
                      .height(section.collapsible ? 18 : 20)
                      .borderRadius(section.collapsible ? 4 : 5)
                      .objectFit(ImageFit.Cover)
                      .onError(() => {})
                    Text(item.name)
                      .fontSize(12).maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ left: 6 }).layoutWeight(1)
                    if (section.collapsible) {
                      Text(this.isFavBoard(item.fid) ? '★' : '☆')
                        .fontSize(12)
                        .fontColor(this.isFavBoard(item.fid) ? AppColors.primary : AppColors.textTertiary)
                        .margin({ left: 4 })
                        .onClick(() => {
                          this.handleToggleFav(item.fid, item.name)
                        })
                    }
                  }
                  .width('100%').height(section.collapsible ? 30 : 32)
                  .padding({ left: section.collapsible ? 22 : 8, right: 8 })
                  .alignItems(VerticalAlign.Center)
                  .borderRadius(8)
                  .backgroundColor(this.isActiveBoard(item.fid) ? AppColors.bgSecondary : Color.Transparent)
                  .onClick(() => {
                    routerStore.navigateForum(item.fid, item.name)
                  })
                }
              }, (item: SidebarBoardItem) => `${item.fid}`)
            }
          }
        }, (section: SidebarSection) => `${section.id}_${section.collapsed}`)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .cachedCount(2)
      .divider({ strokeWidth: 0.5, color: AppColors.separator })
    }
  }

  @Builder
  CategoryFallbackContent() {
    Column() {
      Text(this.loadError.length > 0 ? this.loadError : '暂无板块')
        .fontSize(14)
        .fontColor(AppColors.textTertiary)
        .textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16 })
      Button('重试')
        .fontSize(13)
        .fontColor(AppColors.primary)
        .backgroundColor(Color.Transparent)
        .margin({ top: 12 })
        .onClick(() => {
          this.retryCategories()
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  SidebarSectionHeader(section: SidebarSection) {
    Row() {
      if (section.collapsible) {
        Text('›')
          .fontSize(14).fontColor(AppColors.textTertiary).margin({ right: 6 })
          .rotate({ angle: section.collapsed ? 0 : 90 })
      }
      if (section.collapsible && section.id !== '__fav__') {
        Image(this.getCategoryIconUrl(section.id))
          .width(18).height(18).borderRadius(4).objectFit(ImageFit.Cover)
          .margin({ right: 6 })
          .onError(() => {})
      }
      Text(section.name)
        .fontSize(section.collapsible ? 13 : 11)
        .fontWeight(FontWeight.Bold)
        .fontColor(section.collapsible ? AppColors.textPrimary : AppColors.textSecondary)
      if (section.collapsible && this.currentBreakpoint !== 'lg') {
        Text(section.items.length.toString())
          .fontSize(11).fontColor(AppColors.textTertiary).margin({ left: 6 })
      }
    }
    .width('100%')
    .padding({ left: 8, right: 8, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (section.collapsible) {
        this.toggleSidebarSection(section)
      }
    })
  }

  @Builder
  MobileContent() {
    Row() {
      Image($r('app.media.icon_search'))
        .width(16).height(16).fillColor(AppColors.textTertiary).margin({ right: 8 })
      Text('搜索板块、主题...')
        .fontSize(15).fontColor(AppColors.textTertiary)
    }
    .width('92%').height(40).padding({ left: 12, right: 12 })
    .backgroundColor(AppColors.bgSecondary).borderRadius(10)
    .margin({ top: 12, bottom: 12 }).alignItems(VerticalAlign.Center)
    .onClick(() => {
      routerStore.navigateSearch()
    })

    if (this.favoritesList.length > 0) {
      this.FavoritesGrid()
    }

    if (this.isLoading) {
      Column() {
        LoadingProgress().width(24).height(24).color(AppColors.textTertiary)
        Text('加载中...').fontSize(14).fontColor(AppColors.textTertiary).margin({ top: 12 })
      }
      .width('100%').height(200)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    } else if (this.categories.length === 0) {
      Column() {
        Text(this.loadError.length > 0 ? this.loadError : '暂无板块')
          .fontSize(14)
          .fontColor(AppColors.textTertiary)
          .textAlign(TextAlign.Center)
        Button('重试')
          .fontSize(13)
          .fontColor(AppColors.primary)
          .backgroundColor(Color.Transparent)
          .margin({ top: 12 })
          .onClick(() => {
            this.retryCategories()
          })
      }
      .width('100%').height(200)
      .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    } else {
      List() {
        LazyForEach(this.categoriesDataSource, (cat: Category) => {
          ListItem() {
            this.CategoryGrid(cat)
          }
        }, (cat: Category) => cat.id)
      }
      .width('100%')
      .divider({ strokeWidth: 8, color: Color.Transparent })
    }
  }

  @Builder
  MobileTwoPanelContent() {
    Row() {
      Scroll() {
        Column() {
          Column() {
            Avatar({
              avatar: this.authState.avatarUrl,
              uid: this.authState.uid,
              name: this.authState.nickName,
              avatarSize: 36
            })
            Text(this.authState.nickName || '未登录')
              .fontSize(13).fontWeight(FontWeight.Bold)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 8 })
          }
          .width('100%')
          .padding({ top: 14 + this.statusBarHeight, bottom: 14 })
          .alignItems(HorizontalAlign.Center)
          .onClick(() => {
            if (this.authState.uid) {
              routerStore.navigateActivity(Screen.profile(this.authState.uid))
            }
          })

          Row() {
            Image($r('app.media.icon_search')).width(14).height(14).fillColor(AppColors.textTertiary).margin({ right: 4 })
            Text('搜索').fontSize(11).fontColor(AppColors.textTertiary)
          }
          .width('100%').height(28).padding({ left: 6, right: 6 })
          .backgroundColor(AppColors.bgSecondary).borderRadius(8)
          .margin({ left: 4, right: 4, top: 6, bottom: 6 })
          .alignItems(VerticalAlign.Center)
          .onClick(() => {
            routerStore.navigateSearch()
          })

          Divider().width('100%').color(AppColors.separator).margin({ top: 4, bottom: 4 })

          if (this.favoritesList.length > 0) {
            this.SidebarTabItem('__fav__', '收藏板块')
          }
          ForEach(this.categories, (cat: Category) => {
            this.SidebarTabItem(cat.id, cat.name)
          }, (cat: Category) => cat.id)
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .padding({ bottom: 6 })
      }
      .width(80).height('100%')
      .backgroundColor(AppColors.bgTertiary)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .border({ width: { right: 0.5 }, color: AppColors.separator })

      if (this.selectedSectionId === '__fav__') {
        this.RightFavContent()
      } else {
        this.RightCategoryContent()
      }
    }
    .width('100%').height('100%')
  }

  @Builder
  SidebarTabItem(id: string, name: string) {
    Column() {
      if (id === '__fav__') {
        Image($r('app.media.icon_star'))
          .width(26).height(26)
          .fillColor(this.selectedSectionId === id ? AppColors.primary : AppColors.textSecondary)
      } else {
        Image(this.getCategoryIconUrl(id))
          .width(26).height(26).borderRadius(6).objectFit(ImageFit.Cover)
          .onError(() => {})
      }
      Text(name)
        .fontSize(12)
        .fontColor(this.selectedSectionId === id ? AppColors.primary : AppColors.textSecondary)
        .fontWeight(this.selectedSectionId === id ? FontWeight.Bold : FontWeight.Regular)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 4 })
    }
    .width('100%').aspectRatio(1.3)
    .padding({ left: 2, right: 2, top: 8, bottom: 4 })
    .backgroundColor(this.selectedSectionId === id ? AppColors.bgSecondary : Color.Transparent)
    .borderRadius(8).margin({ top: 2 })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.selectedSectionId = id
    })
  }

  @Builder
  RightFavContent() {
    Column() {
      if (this.favoritesList.length > 0) {
        Text('收藏板块')
          .fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppColors.primary)
          .width('100%').padding({ left: 12, top: this.statusBarHeight + 8, bottom: 6 })

        List() {
          ForEach(this.favoritesList, (fav: FavBoard) => {
            ListItem() {
              Row() {
                Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${fav.fid}.png`)
                  .width(36).height(36).borderRadius(8).objectFit(ImageFit.Cover)
                  .onError(() => {})
                Text(fav.name)
                  .fontSize(14).fontColor(AppColors.textPrimary).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: 10 }).layoutWeight(1)
                Text('★')
                  .fontSize(16).fontColor(AppColors.primary)
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.handleToggleFav(fav.fid, fav.name)
                  })
              }
              .width('100%').height(52).padding({ left: 12, right: 12 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                routerStore.navigateForum(fav.fid, fav.name)
              })
            }
          }, (fav: FavBoard) => fav.fid.toString())
        }
        .width('100%').layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: AppColors.separator })
        .scrollBar(BarState.Off)
      }
    }
    .layoutWeight(1).height('100%')
  }

  @Builder
  RightCategoryContent() {
    Column() {
      ForEach(this.categories, (cat: Category) => {
        if (cat.id === this.selectedSectionId) {
          Row() {
            Image(this.getCategoryIconUrl(cat.id))
              .width(18).height(18).borderRadius(4).objectFit(ImageFit.Cover)
              .margin({ right: 8 })
              .onError(() => {})
            Text(cat.name)
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor(AppColors.textPrimary)
          }
          .width('100%').padding({ left: 12, top: this.statusBarHeight + 8, bottom: 6 })
          .alignItems(VerticalAlign.Center)

          if (this.collectBoardsFromCat(cat).length > 0) {
            List() {
              ForEach(this.collectBoardsFromCat(cat), (board: BoardContent) => {
                ListItem() {
                  Row() {
                    Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${board.fid}.png`)
                      .width(36).height(36).borderRadius(8).objectFit(ImageFit.Cover)
                      .onError(() => {})
                    Column() {
                      Text(board.name)
                        .fontSize(14).fontColor(AppColors.textPrimary).maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (board.info.length > 0) {
                        Text(board.info)
                          .fontSize(11).fontColor(AppColors.textTertiary).maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                          .margin({ top: 2 })
                      }
                    }
                    .margin({ left: 10 }).layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .justifyContent(FlexAlign.Center)
                    Text(this.isFavBoard(board.fid) ? '★' : '☆')
                      .fontSize(16)
                      .fontColor(this.isFavBoard(board.fid) ? AppColors.primary : AppColors.textTertiary)
                      .margin({ left: 8 })
                      .onClick(() => {
                        this.handleToggleFav(board.fid, board.name)
                      })
                  }
                  .width('100%').height(60).padding({ left: 12, right: 12 })
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => {
                    routerStore.navigateForum(board.fid, board.name)
                  })
                }
              }, (board: BoardContent) => board.fid.toString())
            }
            .width('100%').layoutWeight(1)
            .divider({ strokeWidth: 0.5, color: AppColors.separator })
            .scrollBar(BarState.Off)
          } else {
            Text('暂无板块')
              .fontSize(14).fontColor(AppColors.textTertiary).margin({ top: this.statusBarHeight + 40 })
              .width('100%').textAlign(TextAlign.Center)
          }
        }
      }, (cat: Category) => cat.id)
    }
    .layoutWeight(1).height('100%')
  }

  @Builder
  FavoritesGrid() {
    Column() {
      Row() {
        Text('我的收藏')
          .fontSize(13).fontWeight(FontWeight.Bold).fontColor(AppColors.primary)
        Text(`${this.favoritesList.length} 个板块`)
          .fontSize(11).fontColor(AppColors.textTertiary)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 6 })
      .justifyContent(FlexAlign.SpaceBetween)

      GridRow({ columns: { sm: 4, md: 4, lg: 3 }, gutter: 8 }) {
        ForEach(this.favoritesList, (fav: FavBoard) => {
          GridCol() {
            Column() {
              Stack() {
                Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${fav.fid}.png`)
                  .width(44).height(44).borderRadius(12).objectFit(ImageFit.Cover)
                  .onError(() => {})
              }
              .width(44).height(44).borderRadius(12).backgroundColor(AppColors.bgSecondary)

              Text(fav.name)
                .fontSize(11).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 56 })
            }
            .padding({ top: 8, bottom: 8 }).alignItems(HorizontalAlign.Center)
            .onClick(() => {
              routerStore.navigateForum(fav.fid, fav.name)
            })
          }
        })
      }
      .width('100%').padding({ left: 8, right: 8, bottom: 14 })
    }
    .width('92%').backgroundColor(AppColors.bgTertiary).borderRadius(12).margin({ bottom: 8 })
  }

  @Builder
  CategoryGrid(cat: Category) {
    Column() {
      Row() {
        Image(this.getCategoryIconUrl(cat.id))
          .width(16).height(16).borderRadius(4).objectFit(ImageFit.Cover)
          .margin({ right: 6 })
          .onError(() => {})
        Text(cat.name).fontSize(13).fontWeight(FontWeight.Bold)
        Text(this.collectBoardCountForCat(cat).toString())
          .fontSize(11).fontColor(AppColors.textTertiary).margin({ left: 6 })
      }
      .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      GridRow({ columns: { sm: 4, md: 4, lg: 3 }, gutter: 8 }) {
        ForEach(this.collectBoardsFromCat(cat), (board: BoardContent) => {
          GridCol() {
            Column() {
              Stack() {
                Image(`https://img4.nga.178.com/ngabbs/nga_classic/f/app/${board.fid}.png`)
                  .width(40).height(40).borderRadius(10).objectFit(ImageFit.Cover)
                  .onError(() => {})
              }
              .width(40).height(40).borderRadius(10).backgroundColor(AppColors.bgSecondary)

              Text(board.name)
                .fontSize(11).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .constraintSize({ maxWidth: 52 })
                .fontColor(AppColors.textPrimary)
            }
            .padding({ top: 10, bottom: 10 }).alignItems(HorizontalAlign.Center)
            .onClick(() => {
              routerStore.navigateForum(board.fid, board.name)
            })
          }
        })
      }
      .width('100%').padding({ left: 6, right: 6 })
      .backgroundColor(AppColors.bgTertiary).borderRadius(12)
    }
    .width('92%')
  }

  private getCategoryIconUrl(catId: string): string {
    return `https://img4.nga.178.com/ngabbs/nga_classic/f/app/c/${catId}.android_xh.png`
  }

  private isActiveBoard(fid: number): boolean {
    return this.router.boardSlot !== null && this.router.boardSlot.fid === fid
  }

  private collectBoardsFromCat(cat: Category): BoardContent[] {
    const seen = new Set<number>()
    const boards: BoardContent[] = []
    if (cat.sub && Array.isArray(cat.sub)) {
      for (const sub of cat.sub) {
        if (sub.content && Array.isArray(sub.content)) {
          for (const board of sub.content) {
            if (!seen.has(board.fid)) {
              seen.add(board.fid)
              boards.push(board)
            }
          }
        }
      }
    }
    return boards
  }

  private collectBoardCountForCat(cat: Category): number {
    return this.collectBoardsFromCat(cat).length
  }

  private toggleSidebarSection(section: SidebarSection): void {
    const idx = this.sidebarDataSource.indexOf(section.id)
    if (idx < 0) {
      return
    }
    const updated: SidebarSection = {
      id: section.id,
      name: section.name,
      items: section.items,
      collapsed: !section.collapsed,
      collapsible: section.collapsible
    }
    this.sidebarDataSource.updateSection(idx, updated)
  }
}
