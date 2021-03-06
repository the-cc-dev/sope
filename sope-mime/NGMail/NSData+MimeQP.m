/*
  Copyright (C) 2000-2005 SKYRIX Software AG

  This file is part of SOPE.

  SOPE is free software; you can redistribute it and/or modify it under
  the terms of the GNU Lesser General Public License as published by the
  Free Software Foundation; either version 2, or (at your option) any
  later version.

  SOPE is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or
  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
  License for more details.

  You should have received a copy of the GNU Lesser General Public
  License along with SOPE; see the file COPYING.  If not, write to the
  Free Software Foundation, 59 Temple Place - Suite 330, Boston, MA
  02111-1307, USA.
*/

#include "common.h"
#include <string.h>

@implementation NSData(MimeQPHeaderFieldDecoding)

static Class NSStringClass   = Nil;
static Class NGMimeTypeClass = Nil;

- (id)decodeQuotedPrintableValueOfMIMEHeaderField:(NSString *)_name {
  // check data for 8-bit headerfields (RFC 2047 (MIME PART III))
  /*
    TODO: document
    
    This method returns an NSString or an NSData object (or nil).
  */
  enum {
    NGMimeMessageParser_quoted_start   = 1,
    NGMimeMessageParser_quoted_charSet = 2,
    NGMimeMessageParser_quoted_qpData  = 3,
    NGMimeMessageParser_quoted_end     = 4
  } status = NGMimeMessageParser_quoted_start;
  unsigned int        length;
  const unsigned char *bytes, *firstEq;
  BOOL foundQP = NO;

  /* setup statics */
  if (NSStringClass   == Nil) NSStringClass   = [NSString class];
  if (NGMimeTypeClass == Nil) NGMimeTypeClass = [NGMimeType class];

  
  /* begin */
  length = [self length];
  
  /* check whether the string is long enough to be quoted etc */
  if (length <= 6)
    return self;
  
  /* check whether the string contains QP tokens ... */
  bytes = [self bytes];
  
  if ((firstEq = memchr(bytes, '=', length)) == NULL)
    return self;
  
  /* process data ... (quoting etc) */
  {
    unichar       *buffer;
    unsigned int  bufLen, maxBufLen;
    NSString      *charset;
    BOOL          appendLC, encodedLastWord;
    int           cnt, tmp;
    unsigned char encoding;

    buffer = calloc(length + 13, sizeof(unichar));
    
    maxBufLen             = length + 3;
    buffer[maxBufLen - 1] = '\0';
    bufLen                = 0;
    
    encoding = 0;
    tmp      = -1;
    appendLC = YES;
    encodedLastWord = NO;
    charset  = nil;
    status   = NGMimeMessageParser_quoted_start;

    /* copy data up to first '=' sign */
    if ((cnt = (firstEq - bytes)) > 0) {
      for (; bufLen < cnt; bufLen++) 
        buffer[bufLen] = bytes[bufLen];
    }
    
    for (; cnt < (length - 1); cnt++) {
      appendLC = YES;      
      
      if (status == NGMimeMessageParser_quoted_start) {
        if ((bytes[cnt] == '=') && (bytes[cnt + 1] == '?')) { // found begin
          cnt++;
          if (encodedLastWord && tmp != -1) {
            // We must remove the whitespace added since `tmp`
            int i;
            for (i = bufLen - 1; i >= tmp; i--)
              buffer[i] = '\0';
            bufLen = tmp;
          }
          tmp = -1;
          status = NGMimeMessageParser_quoted_charSet;
        } else if (bytes[cnt] == ' ' || bytes[cnt] == '\r' ||
                   bytes[cnt] == '\n' || bytes[cnt] == '\t') {
          // We must ignore whitespace between qp encoded strings.
          // Both are valid:
          // (ab) -> (=?utf-8?q?a?=  =?utf-8?q?b?=)
          // (ab) -> (=?utf-8?q?a?=
          //             =?utf-8?q?b?=)
          if (tmp == -1) // first whitespace found
            tmp = bufLen;
          buffer[bufLen++] = bytes[cnt];
        } else {
          encodedLastWord = NO;
          buffer[bufLen++] = bytes[cnt];
        }
      }
      else if (status == NGMimeMessageParser_quoted_charSet) {
        if (tmp == -1)
          tmp = cnt;
	
        if (bytes[cnt] == '?') {
          charset = 
	    [NSStringClass stringWithCString:(char *)(bytes + tmp) 
			   length:(cnt - tmp)];
          tmp = -1;
	  
          if ((length - cnt) > 2) { 
	    // set encoding (eg 'q' for quoted printable)
            cnt++; // skip '?'
            encoding = bytes[cnt];
            cnt++; // skip encoding
            status = NGMimeMessageParser_quoted_qpData;
          }
          else { // unexpected end
            NSLog(@"WARNING: unexpected end of header");
            appendLC = NO;
            break;
          }
        }
      }
      else if (status == NGMimeMessageParser_quoted_qpData) {
        if (tmp == -1)
          tmp = cnt;
	
        if ((bytes[cnt] == '?') && (bytes[cnt + 1] == '=')) {
          NSData           *tmpData;
          NSString         *tmpStr;
	  unsigned int     tmpLen;
	  
          tmpData = _rfc2047Decoding(encoding, (char *)bytes + tmp, cnt - tmp);
	  foundQP = YES;

	  /* 
	     create a temporary string for charset conversion ... 
	     Note: the headerfield is currently held in ISO Latin 1
	  */
	  tmpStr = [NSStringClass stringWithData:tmpData
			      usingEncodingNamed:charset];

          if (tmpStr == nil) {
            NSStringEncoding enc;
            
            enc    = [NGMimeTypeClass stringEncodingForCharset:charset];
            tmpStr = [[[NSStringClass alloc] initWithData:tmpData encoding:enc]
                                      autorelease];

	    // Fall-back to ISO Latin 1 if the decoding using the specified charset
	    // has failed. Note that we shouldn't be doing this here, we should let
	    // the application decide what to do but SOPE is just too lame and does
	    // not expose a failure vs. the initial value of the header
	    if (!tmpStr)
	      tmpStr = [[[NSStringClass alloc] initWithData:tmpData
						   encoding:NSISOLatin1StringEncoding]
			 autorelease];
          }
	  tmpLen = [tmpStr length];

	  if ((tmpLen + bufLen) < maxBufLen) {
	    [tmpStr getCharacters:(buffer + bufLen)];
	    bufLen += tmpLen;
	  }
	  else {
	    [self errorWithFormat:@"%s: quoted data to large --> ignored %@",
		  __PRETTY_FUNCTION__, tmpStr];
	  }
          tmp = -1;
          cnt++;
          appendLC = YES;
          status   = NGMimeMessageParser_quoted_start;
          encodedLastWord = YES;
        }
      }
    }
    if (appendLC) {
      if (cnt < length) {
        buffer[bufLen] = bytes[cnt];
        bufLen++;
      }
    }
    buffer[bufLen] = '\0';
    while(bufLen > 1 && buffer[bufLen-1] == '\0')
      bufLen--;
    {
      id data;

      data = nil;
      
      if (buffer && foundQP) {
        static NSCharacterSet *illegalCS = nil;

        if (illegalCS == nil) {
          illegalCS = [NSCharacterSet illegalCharacterSet];
          [illegalCS retain];
        }
        data = [[[NSStringClass alloc] initWithCharacters:buffer length:bufLen]
                                autorelease];
        data = [data stringByTrimmingCharactersInSet: illegalCS];
        if (data == nil) {
          [self warnWithFormat:
		  @"%s: got no string for buffer '%s', length '%i' !", 
                  __PRETTY_FUNCTION__, buffer, bufLen];
        }
      }
      
      if (data == nil)
        data = self; /* we return an NSData */
      
      if (buffer != NULL) free(buffer); buffer = NULL;
      return data;
    }
  }
  return self;
}

@end /* NSData(MimeQPHeaderFieldDecoding) */
