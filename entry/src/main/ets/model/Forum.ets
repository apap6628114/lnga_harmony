/**
 * 版块分类。
 */
export interface Category {
  /** 分类标识。 */
  id: string;
  /** 分类名称。 */
  name: string;
  /** 分类下的分组。 */
  sub: CategorySub[];
}

/**
 * 版块分类中的分组。
 */
export interface CategorySub {
  /** 分组名称。 */
  name: string;
  /** 分组包含的版块。 */
  content: BoardContent[];
}

/**
 * 分类接口返回的版块条目。
 */
export interface BoardContent {
  /** 普通版块 ID。 */
  fid: number;
  /** 专题版块 ID。 */
  stid: number;
  /** 版块名称。 */
  name: string;
  /** 版块说明。 */
  info: string;
  /** 兼容旧布局的版块名称。 */
  nameS: string;
  /** 兼容旧布局的版块说明。 */
  infoS: string;
  /** 版块图标地址。 */
  head: string;
  /** NGA 返回的版块属性位。 */
  bit?: number;
}

/**
 * 官方 APP 版块搜索接口返回的版块条目。
 */
export interface ForumSearchItem {
  /** 普通版块 ID。 */
  fid: string;
  /** 专题版块 ID。 */
  stid: string;
  /** 版块名称。 */
  name: string;
  /** 版块说明。 */
  info: string;
}

/**
 * 可导航的版块。
 */
export interface Board {
  /** 普通版块 ID。 */
  fid: number;
  /** 专题版块 ID。 */
  stid: number;
  /** 版块名称。 */
  name: string;
  /** 版块图标地址。 */
  boardHead: string;
}

/**
 * 父版块帖子列表返回的子版块关系。
 */
export interface SubBoard extends Board {
  /** 兼容旧模型的筛选标识。 */
  tidStr: string;
  /** NGA 返回的子版块属性值。 */
  type: number;
  /** 当前是否在父版块帖子列表中显示。 */
  checked: boolean;
  /** 子版块说明。 */
  description: string;
  /** 父版块 ID 字符串。 */
  parentFidStr: string;
  /** 提交 NGA 子版块显示设置时使用的标识。 */
  filterId: string;
  /** NGA 返回的原始子版块属性值。 */
  attributes: number;
  /** 当前子版块是否允许用户屏蔽。 */
  filterable: boolean;
}

/**
 * 版块分类树节点。
 */
export interface BoardCategory {
  /** 分类名称。 */
  categoryName: string;
  /** 是否为收藏分类。 */
  isBookmarkCategory: boolean;
  /** 分类直属版块。 */
  boardList: Board[];
  /** 下级分类。 */
  subCategoryList: BoardCategory[];
}
