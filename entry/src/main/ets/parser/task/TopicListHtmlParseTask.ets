import { parseHtmlTopicListToRawJson } from '../nga/html-topiclist/index'

@Concurrent
function parseTopicListHtmlTask(html: string): Object {
  return parseHtmlTopicListToRawJson(html) as Object
}

export { parseTopicListHtmlTask }
