module Action where

import Bootstrap (btnLight)
import Data.Foldable (intercalate)
import Data.Newtype (unwrap)
import Halogen (HTML)
import Halogen.HTML (ClassName(ClassName), button, div, div_, h3_, text)
import Halogen.HTML.Properties (class_)
import Icons (Icon(..), icon)
import Prelude (pure, ($), (<$>), (<<<))
import Types (Action)
import Wallet (walletIdPane)

actionsPane :: forall p i. Array Action -> HTML p i
actionsPane actions =
  div [ class_ $ ClassName "actions" ]
    [ h3_ [ text "Actions" ]
    , div_
      (
        intercalate
          [ icon LongArrowDown ]
          (pure <<< actionPane <$> actions)
      )
    ]

actionPane :: forall p i. Action -> HTML p i
actionPane action =
  div [ class_ $ ClassName "action" ]
    [ button [ btnLight ]
      [ div_ [ text (unwrap action.actionId) ]
      , div_ [ walletIdPane action.walletId ]
      ]
    ]