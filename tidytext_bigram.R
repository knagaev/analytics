library(xml2)
library(stringr)
library(tidyverse) #load second!
library(forcats)
library(tidytext)
library(ggplot2)
library(tm)
library(slam)

main_path <- "C:\\PLR\\catalys\\PsDocs\\PsDocs 2017-06-16"


get_propvar <- function(xml_file)
{
  id <- tail(str_split(dirname(xml_file), "/")[[1]], 1)
  
  xml <- read_xml(xml_file, encoding = "UTF-8")
  
  title <- unlist(xml_text(xml_find_all(xml, "//ru-b542")))
  description <- unlist(xml_text(xml_find_all(xml, "description")))
  claims <- unlist(xml_text(xml_find_all(xml, "claims")))
  abstract <- unlist(xml_text(xml_find_all(xml, "abstract")))
  
  data.frame(
    id = id,
    title = ifelse(length(title) > 0, title, ""),
    description = ifelse(length(description) > 0, description, ""),
    claims = ifelse(length(claims) > 0, claims, ""),
    abstract = ifelse(length(abstract) > 0, abstract, ""))
}

psdocs <- dir(main_path, pattern = "*.xml", full.names = TRUE, recursive = TRUE) %>% 
  map(get_propvar) %>% 
  bind_rows

#df_corpus <- psdocs %>%
#  transmute(id = id, 
#            text_contents = paste(title, description, claims, abstract, sep = ' '))

df_corpus <- psdocs %>%
  unite(text_contents, title, description, claims, abstract, sep = " ")

# заменяем пунктуацию на пробел
df_corpus$text_contents <- gsub("[[:punct:]]", " ", df_corpus$text_contents)
df_corpus$text_contents <- gsub("[“”\"]", " ", df_corpus$text_contents)
df_corpus$text_contents <- gsub("[^а-яА-Я]", " ", df_corpus$text_contents)

#df_corpus <- column_to_rownames(df_corpus, var = "id")

# сохраняем id документа в поле id
myReader <- readTabular(mapping=list(content="text_contents", id="id"))
wordCorpus <- VCorpus(DataframeSource(df_corpus), readerControl=list(reader=myReader))

#wordCorpus <- tm_map(wordCorpus, removePunctuation)
wordCorpus <- tm_map(wordCorpus, removeNumbers)
wordCorpus <- tm_map(wordCorpus, content_transformer(tolower))
wordCorpus <- tm_map(wordCorpus, removeWords, stopwords("russian"))
wordCorpus <- tm_map(wordCorpus, removeWords, stopwords("english"))

local_stopwords <- c("фиг", "патент", "дата", "публикации", "осуществляется", 
                     "путем", "средства", "является", "который", "содержит", 
                     "относится", "области", "область", "включает", "например", 
                     "имеющий",  "служит", "также", "авт",  "свид", "датчиков", 
                     "средств")
wordCorpus <- tm_map(wordCorpus, removeWords, local_stopwords)
wordCorpus <- tm_map(wordCorpus, stripWhitespace)
#wordCorpus <- tm_map(wordCorpus, content_transformer(stemDocument), "russian")

dtm <- DocumentTermMatrix(wordCorpus, control = list(stemming = FALSE, stopwords = FALSE, wordLengths=c(3, 20),
                                                     bounds = list(global = c(2, Inf)),
                                                     removeNumbers = FALSE, removePunctuation = FALSE))
dim(dtm)

dtms <- removeSparseTerms(dtm, sparse=0.97)
dtmr <- DocumentTermMatrix(wordCorpus, control=list(wordLengths=c(3, 20), bounds = list(global = c(5,45))))

lda_dtm <- dtm

summary(col_sums(lda_dtm))

term_tfidf <- tapply(lda_dtm$v/row_sums(lda_dtm)[lda_dtm$i], lda_dtm$j, mean) * log2(nDocs(lda_dtm)/col_sums(lda_dtm > 0))
dim(term_tfidf)
summary(term_tfidf)

lda_dtm <- lda_dtm[, term_tfidf >= 0.005 & term_tfidf < 0.1]
lda_dtm <- lda_dtm[row_sums(lda_dtm) > 0, ]
summary(col_sums(lda_dtm))
dim(lda_dtm)
lda_term_tfidf <- tapply(lda_dtm$v/row_sums(lda_dtm)[lda_dtm$i], lda_dtm$j, mean) * log2(nDocs(lda_dtm)/col_sums(lda_dtm > 0))

df <- data.frame(term_tfidf = term_tfidf, term = dtm$dimnames[["Terms"]])
df$id <- rownames(df)
df %>% 
  arrange((term_tfidf)) %>% 
  head(1000) %>% 
  tail(20)

ggplot(df, aes(term_tfidf)) + geom_histogram(binwidth = 0.001)
qplot(lda_term_tfidf, geom="histogram")

dtmr$dimnames[["Terms"]][which(term_tfidf > 0.1)]


ap_lda <- LDA(lda_dtm, k = 5, control = list(seed = 1234))

#ap_lda <- jss_TM[["VEM_fixed"]]

ap_topics <- tidy(ap_lda, matrix = "beta")
ap_topics

df1 <- df_corpus %>% 
  filter(str_detect(text_contents, "изг"))
write_excel_csv(df1, "df1.csv")

ap_top_terms <- ap_topics %>%
  unite(sort_term, topic, term, sep = " ", remove = FALSE) %>% 
#  mutate(sort_term = paste0(topic, term, collapse='')) %>% 
  group_by(topic) %>%
  top_n(10, beta) %>%
  ungroup() %>%
  arrange(topic, -beta)


ap_top_terms %>%
  mutate(sort_term = fct_reorder2(sort_term, topic, beta, function(x, y) {-x * 10000 + y}, .desc = FALSE)) %>%
  ggplot(aes(x = sort_term, beta, fill = factor(topic))) +
# geom_bar(stat = "identity", show.legend = TRUE) +
  geom_col(show.legend = TRUE) +
  scale_x_discrete(labels = function(x) str_sub(x, 3)) +
  facet_wrap(~ topic, scales = "free") +
  coord_flip()

beta_spread <- ap_topics %>%
  mutate(topic = paste0("topic", topic)) %>%
  spread(topic, beta) %>%
  filter(topic1 > .001 | topic2 > .001) %>%
  mutate(log_ratio = log2(topic2 / topic1))

beta_spread

ap_documents <- tidy(ap_lda, matrix = "gamma")
ap_documents
write_excel_csv(ap_documents, "ap_documents.csv")


max_topics <- ap_documents %>% 
  group_by(document) %>% 
  filter(gamma == max(gamma))

write_excel_csv(max_topics, "max_topics.csv")

tidy(lda_dtm) %>%
  filter(document == "0002529781_C2_20140927_RU") %>%
  arrange(desc(count))

ap_documents %>% 
  filter(document == "0002529781_C2_20140927_RU")


  

k <- 7
SEED = 1234
jss_TM <-
  list(VEM = LDA(lda_dtm, k = k, control = list(seed = SEED)),
       VEM_fixed = LDA(lda_dtm, k = k,
                       control = list(estimate.alpha = FALSE, seed = SEED)),
       Gibbs = LDA(lda_dtm, k = k, method = "Gibbs",
                   control = list(seed = SEED, burnin = 1000, thin = 100, iter = 1000)),
       CTM = CTM(lda_dtm, k = k,
                 control = list(seed = SEED, var = list(tol = 10^-4), em = list(tol = 10^-3))))

data.frame(dtm$dimnames["Terms"]) %>% 
  arrange(str_length(Terms)) %>% 
  mutate(l = str_length(Terms)) %>% 
  head
