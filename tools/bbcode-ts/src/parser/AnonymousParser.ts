/** 匿名用户名第一、第四位使用的天干地支字符表。 */
const ANONYMOUS_NAME_PRIMARY_CHARS: string = '甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥'

/** 匿名用户名其余位置使用的姓氏字符表。 */
const ANONYMOUS_NAME_SECONDARY_CHARS: string = '王李张刘陈杨黄吴赵周徐孙马朱胡林郭何高罗郑梁谢宋唐许邓冯韩曹曾彭萧蔡潘田董袁于余叶蒋杜苏魏程吕丁沈任姚卢傅钟姜崔谭廖范汪陆金石戴贾韦夏邱方侯邹熊孟秦白江阎薛尹段雷黎史龙陶贺顾毛郝龚邵万钱严赖覃洪武莫孔汤向常温康施文牛樊葛邢安齐易乔伍庞颜倪庄聂章鲁岳翟殷詹申欧耿关兰焦俞左柳甘祝包宁尚符舒阮柯纪梅童凌毕单季裴霍涂成苗谷盛曲翁冉骆蓝路游辛靳管柴蒙鲍华喻祁蒲房滕屈饶解牟艾尤阳时穆农司卓古吉缪简车项连芦麦褚娄窦戚岑景党宫费卜冷晏席卫米柏宗瞿桂全佟应臧闵苟邬边卞姬师和仇栾隋商刁沙荣巫寇桑郎甄丛仲虞敖巩明佘池查麻苑迟邝'

/**
 * 将 NGA 的 `#anony_` 编码用户名转换为六字匿名显示名。
 *
 * @param encoded 服务端返回的用户名
 * @returns 匿名显示名；非匿名用户名保持原值
 */
export function decodeAnonymousName(encoded: string): string {
  if (!encoded || !encoded.startsWith('#anony_')) return encoded
  let offset: number = 6
  let result: string = ''
  for (let index: number = 0; index < 6; index++) {
    if (index === 0 || index === 3) {
      result += ANONYMOUS_NAME_PRIMARY_CHARS.charAt(parseInt(encoded.substr(offset + 1, 1), 16))
    } else {
      result += ANONYMOUS_NAME_SECONDARY_CHARS.charAt(parseInt(encoded.substr(offset, 2), 16))
    }
    offset += 2
  }
  return result || '匿名'
}
