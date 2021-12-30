#Here is my code that:
#1.) Get's the listening history of a lastfm user.
#2.) Creates of df with tracks, artists, number of plays.
#3.) Queries the spotify api's "Search for an item" using track 
  #and artist to get spotify ID.
#4.) Queries the spotify api again using spotify IDs to get audio features.
#5.) Creates of df of tracks, aritsts, number of plays, + audio features.
#6.) Cleans audio feature columns.


#For getting spotify features
#install.packages("spotifyr")
library(spotifyr)

#To get scrobbles
  #May need to install devtools package first:
    #install.packages("devtools")
#devtools::install_github("ppatrzyk/lastfmR")
library(lastfmR)

#For tidyverse syntax and plotting
library(tidyverse)

#For parallel computing
library(foreach)
library(doParallel)

#For date stuff
library(lubridate)

#For bailing out of failed loops
library(R.utils)

#For my_search_spotify
library(httr)
library(jsonlite)

#argument stuff
library(eply)

#for multi arrays
library(abind)

#Here are my api ID's 
my_client_id <- '9c26f0649d9b47c3934844fcfe59c6fa'
my_client_secret <- '1395c21b03a94a289b5d4255d2df8a89'

#Setting them as environment variables for ease of use
Sys.setenv(SPOTIFY_CLIENT_ID = my_client_id)
Sys.setenv(SPOTIFY_CLIENT_SECRET = my_client_secret)

get_lfm_features <- function(user, timezone, par_workers){
  #To get the Spotify features we need to query the api. The spotifyr function 
  #that get's spotify ids is really slow. I edited it slightly so it doesn't
  #seize up so often. Here is that function:
  
  my_search_spotify <- function(q,
                                type = c('album', 'artist', 'playlist', 'track'),
                                market = NULL,
                                limit = 20,
                                offset = 0,
                                include_external = NULL,
                                authorization = get_spotify_access_token(),
                                include_meta_info = FALSE){
    
    base_url <- 'https://api.spotify.com/v1/search'
    
    assertthat::assert_that(
      is.character(q),
      msg = "The parameter 'q' must be a character string."
    )
    
    if (!is.null(market)) {
      assertthat::assert_that(
        str_detect(market, '^[[:alpha:]]{2}$'),
        msg = "The parameter 'market' must be an ISO 3166-1 alpha-2 country code."
      )
    }
    
    assertthat::assert_that(
      (limit >= 1 & limit <= 50) & is.numeric(limit) & limit%%1==0,
      msg = "The parameter 'limit' must be an integer between 1 and 50"
    )
    
    assertthat::assert_that(
      (offset >= 0 & offset <= 10000) & is.numeric(offset) & offset%%1==0,
      msg = "The parameter 'offset' must be an integer between 1 and 50"
    )
    
    
    if (!is.null(include_external)) {
      assertthat::assert_that(
        include_external == 'audio',
        msg = "'include_external' must be 'audio' or an empty string."
      )
    }
    
    params <- list(
      q = q,
      type = paste(type, collapse = ','),
      market = market,
      limit = limit,
      offset = offset,
      include_external = include_external,
      access_token = authorization
    )
    
    res <- GET(base_url,
               query = params,
               encode = 'json',
               timeout(1))
    
    res <- fromJSON(content(res, as = 'text', encoding = 'UTF-8'),
                    flatten = TRUE)
    
    if (!include_meta_info && length(type) == 1) {
      res <- res[[str_glue('{type}s')]]$items %>%
        as_tibble
    }
    
    res
  }
  
  #Next, we need to actually query this function for each track + artist 
  #that we got from last.fm. 
  #Here is that function:
  get_spot_id <- function(tracks){
    #Creating vector of search words (artist name + track name)
    search_vec <- paste(tracks$artist, tracks$track)
    #loop for parallel
    foreach_result <- foreach(
      i = 1:length(search_vec),
      #importing required packages
      .packages = c("httr", "jsonlite", "dplyr", "stringr", "spotifyr", "R.utils"),
      #keeps the results in order
      .inorder = TRUE,
      #combines into vector
      .combine = c,
      #if error pass it so it can be read
      .errorhandling = "pass",
      #importing my function
      .export = "my_search_spotify"
    ) %dopar% {
      #make the search. Silently move on if stuck or slow
      spot_search <-
        R.utils::withTimeout(
          try(
            my_search_spotify(search_vec[i], type = "track"),
            silent = TRUE
          ),
          timeout = 1.01, onTimeout = "silent"
        )
      #initialize id. Stays NA if no results or something goes wrong
      id <- NA
      
      if (class(spot_search) == "try-error") {
        id <- NA
        #if results loop through them until fuzzy match with search vector
      } else if (nrow(spot_search) > 0) {
        for (j in 1:nrow(spot_search)) {
          if (agrepl(
            search_vec[i],
            paste(spot_search$artists[[j]]$name[[1]],
                  spot_search$name[[j]]),
            ignore.case = TRUE
          )) {
            id <- spot_search$id[[j]]
            break
          }
        }
      }
      id
    }
    #Adds column of ids to tracks
    return(add_column(tracks, spotify_id = foreach_result))
  }
  
  #Now we loop through and grab try-errors and slow calls
  scooper <- function(tracks){
    #initializing old count
    missed_count_old <- 1
    #initializing new count
    missed_count_new <- 0
    #getting indexes of missing ids
    missed_indexes <- which(is.na(tracks$spotify_id))
    #while loop that passes until no new ids 
    while(missed_count_old > missed_count_new){
      
      missed_count_old <- length(missed_indexes)
      tracks_missed <- tracks[missed_indexes,]
      tracks_got <- tracks[-missed_indexes,]
      
      tracks_scoop <- get_spot_id(tracks_missed[,c(1:3)])
      tracks <- rbind(tracks_got, tracks_scoop)
      missed_indexes <- which(is.na(tracks$spotify_id))
      missed_count_new <- length(missed_indexes)
    }
    return(tracks)
  }
  
  #Now we can actually gather the Audio features using the IDs
  #Get features function
  get_features <- function(tracks){
    chunk_size <- 100
    chunks <-
      cut_interval(1:nrow(tracks), length = chunk_size, labels = FALSE)
    foreach_result <- foreach(
      i =  1:length(unique(chunks)),
      #importing required packages
      .packages = "spotifyr",
      #keeps the results in order
      .inorder = TRUE,
      #combines into vector
      .combine = rbind,
      #if error pass to it can be read
      .errorhandling = "pass"
    ) %dopar% {
      chunk_features <-
        get_track_audio_features(tracks$spotify_id[which(chunks == i)])
      chunk_features
    }
    foreach_result <- foreach_result %>%
      select(-type,-uri,-track_href,-analysis_url,-id)
    tracks <- add_column(tracks, foreach_result)
    return(tracks)
  }
  
  ###Cleaning Audio Features
  #Cleans key
  clean_key <- function(tracks){
    output_key <- vector(mode = "character", length = nrow(tracks))
    for (i in 1:nrow(tracks)) {
      output_key[[i]] <-
        switch(tracks$key[i] + 1,
               "C",
               "C#",
               "D",
               "D#",
               "E",
               "F",
               "F#",
               "G",
               "G#",
               "A",
               "A#",
               "B")
    }
    tracks$key <- output_key
    return(tracks)
  }
  
  #Cleans Time Signature
  clean_time_signature <- function(tracks){
    output_time_signature <- paste(tracks$time_signature, "/4", sep = "")
    tracks$time_signature <- output_time_signature
    return(tracks)
  }
  
  #Cleaning Mode
  clean_mode <- function(tracks){
    output_mode <- vector(mode = "character", length = nrow(tracks))
    for(i in seq(nrow(tracks))){
      output_mode[[i]] <- switch(tracks$mode[i] + 1, "Minor", "Major")
    }
    tracks$mode <- output_mode
    return(tracks)
  }
  
  #changing duration to seconds
  duration_to_s <- function(tracks){
    tracks$duration_s <- round(tracks$duration_ms/1000)
    tracks <- tracks %>% 
      select(-duration_ms) %>% 
      select(1:17, duration_s, everything())
    return(tracks)
  }
  
  #get scrobbles from user using lastfmR
  scrobbles <- get_scrobbles(user, timezone = timezone)
  
  #Get df of each unique track and how many times they appeared in the listening
  #history i.e. number of plays.
  tracks <- scrobbles %>% 
    group_by(artist, track) %>% 
    count() %>% 
    ungroup() %>% 
    rename(plays = n)
  
  #First pass to get spotify IDs
  #Now we need to Register Parallel workers
  cl <- makeCluster(par_workers)
  registerDoParallel(cl)
  #This will take some time
  tracks <- get_spot_id(tracks)
  
  #Add the IDs from further passes
  tracks <- scooper(tracks)

  #Filter out tracks that didn't get an ID
  tracks <- tracks %>% 
    filter(!is.na(spotify_id))
  
  #Add features to our tracks df
  tracks <- get_features(tracks)
  registerDoSEQ()
  stopCluster(cl) 
  
  #Taking out tracks with no audio features (very rare)
  tracks <- tracks %>% 
    filter(!is.na(danceability))
  
  #cleaning key
  tracks <- clean_key(tracks)
  
  #cleaning time signature
  tracks <- clean_time_signature(tracks)
  
  #cleaning mode
  tracks <- clean_mode(tracks)
  
  #changing duration to seconds
  tracks <- duration_to_s(tracks)
  
  return(tracks)
}

time <- Sys.time()
test <- get_lfm_features(user = "Julianna156789",
                         timezone = "EST",
                         par_workers = 3)
(time <- Sys.time() - time)


time <- Sys.time()
test <- get_lfm_features(user = "eniiler",
                         timezone = "EST",
                         par_workers = 3)
(time <- Sys.time() - time)



get_analysis <- function(tracks){
  foreach_result <- foreach(
    i = 1:nrow(tracks),
    .packages = "spotifyr",
    .inorder = TRUE,
    .errorhandling = "pass"
  ) %dopar% {
    analysis <- NA
    analysis <-
      R.utils::withTimeout(
        try(
          get_track_audio_analysis(tracks$spotify_id[i]),
          silent = TRUE
        ),
        timeout = 5, onTimeout = "silent"
      )
    array(
      c(
        do.call(rbind, analysis$segments$pitches),
        do.call(rbind, analysis$segments$timbre)
      ),
      dim = c(nrow(analysis$segments), 12, 2)
    )
  }

  big_len <- max(sapply(foreach_result, dim)[1,])

  for(i in 1:length(foreach_result)){
    if (
      dim(foreach_result[[i]])[1] < big_len
    ){
      diff <- big_len - dim(foreach_result[[i]])[1]
      zeros <- array(
        data = rep(0, diff*12*2),
        dim = c(diff, 12, 2)
      )
      foreach_result[[i]] <- abind(foreach_result[[i]], zeros, along = 1)
    }
  }
  emty <- array(data = rep(0, nrow(tracks)*big_len*12*2),
                dim = c(nrow(tracks), big_len, 12, 2))
  for(i in 1:length(foreach_result)){
    emty[i,,,] <- foreach_result[[i]]
  }
  return(emty)
}

# cl <- makeCluster(3)
# registerDoParallel(cl)
# time <- Sys.time() 
# my_pitch_timbre <- get_analysis(tracks_w_names[1:700,])
# (time <- Sys.time() - time)
# beep()
# registerDoSEQ()
# stopCluster(cl) 


